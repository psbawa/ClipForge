import Foundation

/// Every knob of moment selection in one place.
public enum SelectionConfig {
    /// Weights of the signal pre-score (each signal is a 0–1 percentile rank across the video's windows).
    static let weights: [(key: String, weight: Double)] = [
        ("loudness", 0.15),     // sustained loud audio
        ("audioPeak", 0.20),    // sudden jumps: shouts, explosions, crowd/voice excitement
        ("motion", 0.15),       // on-screen motion intensity
        ("scenes", 0.10),       // scene-change density
        ("speech", 0.10),       // speech density + exclamations/questions
        ("transcript", 0.30),   // Claude Haiku's hook/interest rating of what's said
        ("watch", 0.30),        // Claude Haiku watching the whole video (contact sheets)
    ]
    /// Finished videos: non-overlapping-ish transcript windows rated in parallel.
    static let transcriptWindow = 360.0
    static let transcriptStep = 300.0
    static let transcriptConcurrency = 4
    /// Final score = signals × signalShare + vision rating × (1 − signalShare).
    static let signalShare = 0.4
    static let windowSeconds = 30.0
    static let stepSeconds = 5.0
    static let topForVision = 8
    static let framesPerCandidate = 3
    /// Visual clipper: a cheap Haiku look (4 frames each) at this many windows picks which ones Sonnet rates.
    static let topForTriage = 40
    static let triageFrames = 4
    static let triageModel = "claude-haiku-5-5"
    static let triageShare = 0.5     // Sonnet shortlist = signals × (1 − share) + Haiku look × share
    static let triageSystem = """
    You triage gameplay moments for a Shorts editor. Each candidate is a time window with 4 frames and a list of detected
    events (HUD text, sounds). For each: score 0-100 for how likely it holds a share-worthy moment (kills, wins, clutch plays,
    crashes, fails, big reactions); menus, maps, loading screens, walking and idle time score low. label: max 8 words on what happens.
    Output ONLY a JSON array: [{"index": 1, "score": 55, "label": "..."}]
    """
    static let leadIn = 3.0          // seconds before the peak the clip must include
    static let payoff = 4.0          // seconds after the peak the clip must include
    static let maxClipsPerVideo = 5
    static let extraClipMinScore = 60 // clips beyond the per-video minimum need at least this final score
    static let sceneCutScore = 30.0   // scdet score that counts as a cut in the per-second series
    static let model = "claude-sonnet-5-5"
    static let effort = "medium"

    static let system = """
    You rate moments from a long video for a YouTube Shorts / TikTok / Reels editor. Each candidate is a time window chosen by audio/visual signals (loudness peaks, motion, scene changes, speech). For each you get its signal strengths, the transcript inside it and a few frames.

    Rate how share-worthy each moment is as a stand-alone vertical short (0-100): would a stranger stop scrolling, watch to the end and share it? Look at the frames to see what actually happens: kills, wins, fails, clutch plays, kill-feed or score changes, crashes, explosions, big reactions, punchlines, surprising statements. Penalize menus, loading screens, maps, calm walking, talking with nothing happening, and anything that needs missing context. Detected events come from on-screen text recognition and a sound classifier and can be wrong; trust the frames when they disagree. Be calibrated: most candidates are 30-70; reserve 85+ for genuinely great moments.

    For each candidate also give:
    - reason: one line (max 120 chars) naming what happens and why it works, e.g. "Triple kill through smoke with the last bullet — clear payoff".
    - peak: the single second (absolute, inside the window) where the key moment lands.
    - title: max 70 characters, accurate, curiosity-driven, no hashtags.
    - description: 1-2 short sentences.
    - hashtags: 3-6 items starting with #, include #Shorts.
    - tags: 5-10 lowercase keywords without #.

    Output ONLY a JSON array, one object per candidate, using its index:
    [{"index": 1, "score": 72, "reason": "...", "peak": 812.5, "title": "...", "description": "...", "hashtags": ["#Shorts"], "tags": ["..."]}]
    """
}

/// One candidate window with its explainable scores.
struct MomentCandidate: Codable, Sendable {
    var index = 0
    var start: Double
    var end: Double
    var peak: Double
    var signals: [String: Double]           // 0–1 percentile per signal
    var preScore: Double                    // weighted signal score, 0–1
    var vision: Int?
    var reason = ""
    var title = "", description = "", hashtags: [String] = [], tags: [String] = []
    var frames: [String] = []
    var events = ""                         // HUD/audio events inside the window, for the model and the review screen
    var triage: Int?
    var triageLabel = ""
    var final: Double { vision.map { SelectionConfig.signalShare * preScore * 100 + (1 - SelectionConfig.signalShare) * Double($0) } ?? preScore * 100 }
}

enum MomentFinder {
    /// Candidate windows across the whole video, scored on signals. Pure; unit-tested.
    static func windows(_ sig: StorySignals, words: [Word], transcriptRatings: [Highlight], duration: Double,
                        events: [GameEvent] = [], weights: [(key: String, weight: Double)] = SelectionConfig.weights, watch: [Double] = [],
                        length: Double = SelectionConfig.windowSeconds, step: Double = SelectionConfig.stepSeconds) -> [MomentCandidate] {
        let n = sig.motion.count
        guard n > 0, duration > 0 else { return [] }
        // Per-second features.
        let loud = sig.loudness
        let jump: [Double] = (0..<n).map { i in
            let prev = loud[max(0, i - 8)..<i].sorted()
            return prev.isEmpty ? 0 : max(0, loud[i] - prev[prev.count / 2])
        }
        var speech = [Double](repeating: 0, count: n)
        for w in words {
            let i = min(n - 1, max(0, Int(w.start)))
            speech[i] += 1 + (w.text.contains("!") || w.text.contains("?") ? 2 : 0)
        }
        let cut = sig.scene.map { $0 >= SelectionConfig.sceneCutScore ? 1.0 : 0.0 }
        var hud = [Double](repeating: 0, count: n), sfx = [Double](repeating: 0, count: n)
        for e in events {
            let i = min(n - 1, max(0, Int(e.time)))
            if e.source == .hud { hud[i] += e.weight } else { sfx[i] += e.weight }
        }
        func topMean(_ v: [Double], _ lo: Int, _ hi: Int) -> Double {
            let s = v[lo...hi].sorted(by: >)
            return s.prefix(3).reduce(0, +) / Double(min(3, s.count))
        }
        let len = min(length, duration)
        var raw: [(s: Double, e: Double, peak: Double, v: [String: Double])] = []
        var t = 0.0
        while t + len <= duration + 0.01 {
            let lo = min(n - 1, Int(t)), hi = min(n - 1, max(lo, Int(t + len) - 1))
            let rated = transcriptRatings.filter { min($0.end, t + len) - max($0.start, t) > 0 }.map { Double($0.score) / 100 }.max() ?? 0
            let combined = (lo...hi).map { loud[$0] / 10 + jump[$0] + sig.motion[$0] + speech[$0] + 3 * hud[$0] + 2 * sfx[$0] + 3 * (watch.indices.contains($0) ? watch[$0] : 0) }
            let peakIdx = lo + (combined.indices.max { combined[$0] < combined[$1] } ?? 0)
            raw.append((t, t + len, Double(peakIdx) + 0.5, [
                "loudness": topMean(loud, lo, hi), "audioPeak": topMean(jump, lo, hi), "motion": topMean(sig.motion, lo, hi),
                "scenes": cut[lo...hi].reduce(0, +), "speech": speech[lo...hi].reduce(0, +), "transcript": rated,
                "hud": hud[lo...hi].reduce(0, +), "events": sfx[lo...hi].reduce(0, +),
                "watch": watch.isEmpty ? 0 : topMean(watch + [Double](repeating: 0, count: max(0, n - watch.count)), lo, hi),
            ]))
            t += step
        }
        // Percentile-rank each signal across windows so loud videos and quiet videos compare fairly.
        var ranked = raw.map { MomentCandidate(start: $0.s, end: $0.e, peak: $0.peak, signals: [:], preScore: 0) }
        for (key, _) in weights {
            let vals = raw.map { $0.v[key] ?? 0 }
            let sorted = vals.sorted()
            for i in raw.indices {
                let v = vals[i]
                // Constant signal (e.g. no speech at all) carries no information → 0 for everyone.
                ranked[i].signals[key] = sorted.first == sorted.last ? 0
                    : Double(sorted.lastIndex { $0 <= v }! + sorted.firstIndex { $0 >= v }!) / 2 / Double(max(sorted.count - 1, 1))
            }
        }
        let wsum = weights.map(\.weight).reduce(0, +)
        for i in ranked.indices {
            ranked[i].events = GameplayScanner.summary(events, from: ranked[i].start, to: ranked[i].end)
            ranked[i].preScore = weights.reduce(0) { $0 + $1.weight * (ranked[i].signals[$1.key] ?? 0) } / wsum
        }
        return ranked
    }

    /// Best non-overlapping windows by pre-score.
    static func top(_ c: [MomentCandidate], count: Int = SelectionConfig.topForVision) -> [MomentCandidate] {
        var out: [MomentCandidate] = []
        for x in c.sorted(by: { $0.preScore > $1.preScore }) where out.count < count {
            if !out.contains(where: { min($0.end, x.end) - max($0.start, x.start) > 0.3 * (x.end - x.start) }) { out.append(x) }
        }
        return out.sorted { $0.start < $1.start }.enumerated().map { var m = $1; m.index = $0 + 1; return m }
    }

    /// Cut times from the per-second scene score (±0.5 s; the render refines edges against exact cuts).
    static func cuts(_ sig: StorySignals) -> [Double] {
        sig.scene.enumerated().filter { $0.element >= SelectionConfig.sceneCutScore }.map { Double($0.offset) + 0.5 }
    }

    struct Triage: Decodable, Validatable {
        var index: Int, score: Int, label: String
        var isValid: Bool { index > 0 && (0...100).contains(score) }
    }

    /// Haiku looks at 4 frames + events of many windows; returns the `count` best (by signals + look) for Sonnet.
    /// An unusable answer is not fatal: the shortlist falls back to signals alone (Sonnet still rates every pick).
    static func triage(_ cands: [MomentCandidate], count: Int = SelectionConfig.topForVision, client: LLMClient, cost: CostTracker,
                       settings: AppSettings) async throws -> [MomentCandidate] {
        guard cands.count > count else { return cands }
        var out = cands
        var content: [LLMContent] = [.text("Candidates:")]
        for c in cands {
            content.append(.text("Candidate \(c.index): \(String(format: "%.0f–%.0f", c.start, c.end)) s" + (c.events.isEmpty ? "" : " · events: \(c.events)")))
            for f in c.frames { if let d = try? Data(contentsOf: URL(fileURLWithPath: f)) { content.append(.jpeg(d)) } }
        }
        content.append(.text("Return the JSON array now."))
        guard await cost.canSpend(budget: settings.dailyBudgetUSD) else { throw HighlightError.budgetReached }
        let r = try await client.complete(model: SelectionConfig.triageModel, system: SelectionConfig.triageSystem, content: content, maxTokens: 4000, effort: "low")
        await cost.record(r.usage, price: settings.prices[SelectionConfig.triageModel])
        if let t: [Triage] = HighlightLogic.decode(r.text) {
            for x in t { if let i = out.firstIndex(where: { $0.index == x.index }) { out[i].triage = x.score; out[i].triageLabel = String(x.label.prefix(80)) } }
        } else {
            Log.ai.error("Triage answer unusable; shortlisting on signals only")
        }
        let s = SelectionConfig.triageShare
        let short = out.sorted { a, b in
            (a.preScore * 100 * (1 - s) + Double(a.triage ?? Int(a.preScore * 100)) * s) > (b.preScore * 100 * (1 - s) + Double(b.triage ?? Int(b.preScore * 100)) * s)
        }.prefix(count)
        return short.sorted { $0.start < $1.start }.enumerated().map { var m = $1; m.index = $0 + 1; return m }
    }

    struct Rating: Decodable, Validatable {
        var index: Int, score: Int, reason: String, peak: Double, title: String, description: String, hashtags: [String], tags: [String]
        var isValid: Bool { index > 0 && (0...100).contains(score) && !title.isEmpty && !reason.isEmpty && peak.isFinite }
    }

    /// Vision pass: transcript + frames of the top candidates → share-worthiness, reason, peak, metadata.
    /// Throws (never silently skips) if the model's answer is unusable twice.
    static func rate(_ cands: [MomentCandidate], words: [Word], client: LLMClient, cost: CostTracker, settings: AppSettings) async throws -> [MomentCandidate] {
        var content: [LLMContent] = [.text("Candidates (times in seconds on the source video):")]
        for c in cands {
            let sig = c.signals.sorted { $0.key < $1.key }.map { "\($0.key) \(Int($0.value * 100))" }.joined(separator: " · ")
            let said = words.slice(c.start, c.end).joinedText
            content.append(.text("Candidate \(c.index): \(String(format: "%.1f–%.1f", c.start, c.end)) s · signal peak at \(String(format: "%.1f", c.peak)) s · \(sig)"
                + (c.events.isEmpty ? "" : "\nDetected events (HUD text / sounds): \(c.events)")
                + (c.triageLabel.isEmpty ? "" : "\nFirst look: \(c.triageLabel)")
                + "\nTranscript: \(said.isEmpty ? "(no speech)" : said)"))
            for f in c.frames { if let d = try? Data(contentsOf: URL(fileURLWithPath: f)) { content.append(.jpeg(d)) } }
        }
        content.append(.text("Return the JSON array now."))
        var problem = ""
        for attempt in 0..<2 {
            guard await cost.canSpend(budget: settings.dailyBudgetUSD) else { throw HighlightError.budgetReached }
            let msg = attempt == 0 ? content : content + [.text("Your previous answer was rejected: \(problem). Return only the corrected JSON array.")]
            let r = try await client.complete(model: SelectionConfig.model, system: SelectionConfig.system, content: msg, maxTokens: 6000, effort: SelectionConfig.effort)
            await cost.record(r.usage, price: settings.prices[SelectionConfig.model])
            guard let ratings: [Rating] = HighlightLogic.decode(r.text), !ratings.isEmpty else { problem = "not a valid JSON array in the required shape"; continue }
            var out = cands
            for rt in ratings {
                guard let i = out.firstIndex(where: { $0.index == rt.index }) else { continue }
                out[i].vision = rt.score
                out[i].reason = String(rt.reason.prefix(160))
                out[i].peak = min(max(rt.peak, out[i].start), out[i].end)
                out[i].title = rt.title; out[i].description = rt.description
                out[i].hashtags = rt.hashtags; out[i].tags = rt.tags
            }
            let missing = out.filter { $0.vision == nil }.map(\.index)
            guard missing.isEmpty else { problem = "candidates \(missing) were not rated"; continue }
            return out
        }
        throw ClipForgeError("Moment rating failed: Claude's answer was unusable twice (\(problem)).")
    }

    /// Final ranking → highlights with boundaries. Overlaps removed; the peak always has lead-in and payoff.
    static func pick(_ rated: [MomentCandidate], words: [Word], cuts: [Double], duration: Double, settings s: AppSettings) -> [Highlight] {
        var chosen: [MomentCandidate] = []
        for c in rated.sorted(by: { $0.final > $1.final }) where chosen.count < SelectionConfig.maxClipsPerVideo {
            guard chosen.count < s.minClipsPerVideo || Int(c.final) >= SelectionConfig.extraClipMinScore else { continue }
            if chosen.contains(where: { abs($0.peak - c.peak) < SelectionConfig.windowSeconds / 2 }) { continue }
            chosen.append(c)
        }
        return chosen.compactMap { c in
            let coreStart = max(0, c.peak - SelectionConfig.leadIn), coreEnd = min(duration, c.peak + SelectionConfig.payoff)
            // The detected events travel with the reason, so "Why this clip" shows what was seen and heard.
            let why = c.reason + (c.events.isEmpty ? "" : "\nDetected: " + c.events)
            var h = Highlight(start: coreStart, end: coreEnd, title: HighlightLogic.shortsTitle(c.title), hook: "", score: Int((c.preScore * 100).rounded()), reason: why)
            h.finalScore = Int(c.final.rounded())
            h.description = c.description + (c.hashtags.isEmpty ? "" : "\n\n" + c.hashtags.joined(separator: " "))
            h.tags = c.tags
            h.signals = c.signals.mapValues { Int(($0 * 100).rounded()) }.merging(["vision": c.vision ?? 0, "final": Int(c.final.rounded())]) { $1 }
            if let n = HighlightLogic.normalize(h, words: words, settings: s, cuts: cuts) { return n }
            // No speech near the peak: centre a minimum-length clip on it, edges on scene cuts when close.
            var out = h
            let half = s.minClipSeconds / 2
            var a = max(0, min(coreStart, c.peak - half))
            if let cs = cuts.filter({ $0 <= coreStart && coreStart - $0 <= 3 }).max() { a = cs }
            var b = min(duration, max(coreEnd, a + s.minClipSeconds))
            if let ce = cuts.filter({ $0 >= b && $0 - b <= 3 }).min() { b = min(duration, ce) }
            out.start = a; out.end = b; out.coreStart = coreStart; out.coreEnd = coreEnd
            return out
        }
    }

    /// Human-readable candidate table for logs and selection.json.
    static func table(_ c: [MomentCandidate]) -> String {
        c.sorted { $0.final > $1.final }.map { x in
            String(format: "#%d %6.1f–%6.1f peak %6.1f | pre %3d vision %3@ final %3d | ", x.index, x.start, x.end, x.peak, Int(x.preScore * 100),
                   x.vision.map { "\($0)" } ?? "—", Int(x.final))
                + SelectionConfig.weights.map { "\($0.key) \(Int((x.signals[$0.key] ?? 0) * 100))" }.joined(separator: " ")
                + (x.reason.isEmpty ? "" : " | \(x.reason)")
        }.joined(separator: "\n")
    }
}
