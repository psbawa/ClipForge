import Foundation

public struct StoryBeat: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var purpose: String
    public var start: Double
    public var end: Double
    public var caption: String
    public var importantAudio: Bool
    /// Transition into this beat: cut / fade / flash / zoom / whip (nil = style default).
    public var transition: String?
    /// 1 = normal, 0.5 = slow motion.
    public var speed: Double = 1
    /// Pro Editor: punch-in scale (nil = none) and sound effects ("whoosh", "hit", "riser").
    public var zoom: Double?
    public var sfx: [String]?
    /// Vlog Editor: which imported file this beat comes from, and its chapter.
    public var asset: String?
    public var chapter: Int?

    enum CodingKeys: String, CodingKey { case purpose, start, end, caption, importantAudio = "important_audio", transition, speed, zoom, sfx, asset, chapter }

    public init(purpose: String, start: Double, end: Double, caption: String, importantAudio: Bool, transition: String? = nil, speed: Double = 1) {
        self.purpose = purpose; self.start = start; self.end = end; self.caption = caption
        self.importantAudio = importantAudio; self.transition = transition; self.speed = speed
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        purpose = try c.decode(String.self, forKey: .purpose)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        importantAudio = try c.decodeIfPresent(Bool.self, forKey: .importantAudio) ?? false
        transition = try c.decodeIfPresent(String.self, forKey: .transition)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom)
        sfx = try c.decodeIfPresent([String].self, forKey: .sfx)
        asset = try c.decodeIfPresent(String.self, forKey: .asset)
        chapter = try c.decodeIfPresent(Int.self, forKey: .chapter)
    }

    public var duration: Double { end - start }
    /// Length in the output (slow motion stretches it).
    public var outDuration: Double { duration / max(speed, 0.25) }
}

public struct Storyboard: Codable, Sendable, Equatable {
    public var mood: String
    public var title: String
    public var description: String
    public var hashtags: [String]
    public var beats: [StoryBeat]
    /// Pro Editor: "why I edited it this way" + which style was applied.
    public var notes: String?
    public var styleID: String?

    enum CodingKeys: String, CodingKey { case mood, title, description, hashtags, beats, notes, styleID }

    public init(mood: String, title: String, description: String, hashtags: [String], beats: [StoryBeat], notes: String? = nil, styleID: String? = nil) {
        self.mood = mood; self.title = title; self.description = description; self.hashtags = hashtags
        self.beats = beats; self.notes = notes; self.styleID = styleID
    }

    /// Tolerant: models often send "notes" as a list of lines, and may omit description/hashtags.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mood = try c.decodeIfPresent(String.self, forKey: .mood) ?? "epic"
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        hashtags = try c.decodeIfPresent([String].self, forKey: .hashtags) ?? []
        beats = try c.decode([StoryBeat].self, forKey: .beats)
        notes = Self.lines(c, .notes)
        styleID = try c.decodeIfPresent(String.self, forKey: .styleID)
    }

    static func lines<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ k: K) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: k) { return s }
        return (try? c.decodeIfPresent([String].self, forKey: k))?.joined(separator: "\n")
    }

    public var tone: StoryTone { StoryTone(rawValue: mood) ?? .epic }
    /// Output length after transitions and speed changes.
    public var outputDuration: Double { StoryTimeline.duration(beats) }
}

/// Where each beat lands in the output (beats overlap by their incoming transition; speed stretches them).
public enum StoryTimeline {
    static let transitions = ["cut", "fade", "flash", "zoom", "whip"]

    /// ffmpeg xfade name and duration for the transition into `b` (beat index > 0).
    static func transition(_ b: StoryBeat) -> (name: String, duration: Double) {
        switch b.transition ?? (b.purpose == "climax" ? "flash" : "fade") {
        case "cut": ("fade", 0.04)
        case "flash": ("fadewhite", StoryConfig.crossfade)
        case "zoom": ("zoomin", 0.3)
        case "whip": ("slideleft", 0.22)
        default: ("fade", StoryConfig.crossfade)
        }
    }

    static func starts(_ beats: [StoryBeat]) -> [Double] {
        var t = 0.0, out: [Double] = []
        for (i, b) in beats.enumerated() {
            if i > 0 { t -= transition(b).duration }
            out.append(t)
            t += b.outDuration
        }
        return out
    }

    static func duration(_ beats: [StoryBeat]) -> Double {
        guard let last = beats.last else { return 0 }
        return starts(beats).last! + last.outDuration
    }

    /// Source-time words → output-time words, per beat (scaled by beat speed).
    static func words(_ words: [Word], beats: [StoryBeat]) -> [Word] {
        zip(beats, starts(beats)).flatMap { b, o in
            words.filter { $0.start >= b.start && $0.end <= b.end }
                .map { Word($0.text, o + ($0.start - b.start) / b.speed, o + ($0.end - b.start) / b.speed) }
        }
    }
}

enum StoryWriter {
    static let purposes: Set<String> = ["hook", "buildup", "climax", "payoff"]

    static func parse(_ text: String) -> Storyboard? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b else { return nil }
        return try? JSONDecoder().decode(Storyboard.self, from: Data(text[a...b].utf8))
    }

    static let remixPurposes: Set<String> = purposes.union(["moment", "countdown"])

    /// nil = valid; otherwise what's wrong (sent back to the model on retry).
    static func validate(_ sb: Storyboard, moments: [StoryMoment], duration: Double, style: RemixStyle = .story) -> String? {
        let b = sb.beats
        let count = style == .story ? 3...8 : 4...40
        guard count.contains(b.count) else { return "use \(count.lowerBound) to \(count.upperBound) beats (got \(b.count))" }
        let allowed = style == .story ? purposes : remixPurposes
        if let bad = b.first(where: { !allowed.contains($0.purpose) }) { return "unknown purpose \"\(bad.purpose)\"" }
        guard b.first?.purpose == "hook" else { return "the first beat must be the hook" }
        if style == .story {
            guard b.last?.purpose == "payoff" else { return "the last beat must be the payoff" }
            guard b.contains(where: { $0.purpose == "climax" }) else { return "include a climax beat" }
        }
        if style == .recap, zip(b.dropFirst(), b.dropFirst(2)).contains(where: { $0.start > $1.start }) {
            return "recap beats after the hook must be in chronological order"
        }
        let seg = style.segment
        for (i, x) in b.enumerated() {
            guard x.start.isFinite, x.end.isFinite, x.start >= 0, x.end <= duration + 0.5, x.end > x.start else {
                return "beat \(i + 1) has invalid times \(x.start)–\(x.end) (video is \(Int(duration)) s)"
            }
            let minLen = i == 0 ? min(StoryConfig.minBeatSeconds, seg.lowerBound) : max(StoryConfig.minBeatSeconds, seg.lowerBound - 0.3)
            guard x.duration >= minLen else { return "beat \(i + 1) is shorter than \(String(format: "%.1f", minLen)) s" }
            guard style == .story || x.duration <= seg.upperBound + 1 else { return "beat \(i + 1) is longer than \(Int(seg.upperBound)) s" }
            guard moments.contains(where: { $0.contains(x.start, x.end) }) else { return "beat \(i + 1) (\(x.start)–\(x.end)) is not inside any candidate window" }
            guard !x.caption.trimmingCharacters(in: .whitespaces).isEmpty, x.caption.count <= 60 else { return "beat \(i + 1) caption must be 1–60 characters" }
            if let t = x.transition, !StoryTimeline.transitions.contains(t) { return "beat \(i + 1) has unknown transition \"\(t)\"" }
            guard (0.25...1).contains(x.speed) else { return "beat \(i + 1) speed must be between 0.25 and 1" }
        }
        if style.isRemix {
            // No overlapping source time between beats (the hook may tease a later moment).
            for i in 1..<b.count { for j in (i + 1)..<max(b.count, i + 1) where min(b[i].end, b[j].end) - max(b[i].start, b[j].start) > 0.2 {
                return "beats \(i + 1) and \(j + 1) overlap in source time"
            } }
        }
        guard !sb.title.isEmpty else { return "title is empty" }
        return nil
    }

    /// Deterministic length fix: trim the longest beats or extend inside their windows until within tolerance of the target.
    static func fit(_ sb: Storyboard, target: Double, moments: [StoryMoment], duration: Double,
                    style: RemixStyle = .story, vertical: Bool = true) -> Storyboard {
        var out = sb
        let tol = StoryConfig.lengthTolerance
        let minLen = max(StoryConfig.minBeatSeconds, style == .story ? 0 : style.segment.lowerBound - 0.3)
        let maxLen = style == .story ? .infinity : style.segment.upperBound
        var guardSteps = 0
        while out.outputDuration > target * (1 + tol), guardSteps < 1000 {
            guardSteps += 1
            // Trim 0.25 s from the end of the longest non-hook beat that can spare it.
            guard let i = out.beats.indices.filter({ out.beats[$0].purpose != "hook" && out.beats[$0].duration > minLen + 0.25 })
                .max(by: { out.beats[$0].outDuration < out.beats[$1].outDuration }) else { break }
            out.beats[i].end -= 0.25
        }
        while out.outputDuration < target * (1 - tol), guardSteps < 2000 {
            guardSteps += 1
            // Extend the shortest beat that still has room inside its window (and its style's max length).
            let room: (Int) -> Double = { i in
                let b = out.beats[i]
                let limit = moments.filter { $0.contains(b.start, b.end) }.map(\.end).max() ?? b.end
                return min(min(limit, duration) - b.end, maxLen - b.duration)
            }
            guard let i = out.beats.indices.filter({ room($0) >= 0.25 }).min(by: { out.beats[$0].outDuration < out.beats[$1].outDuration }) else { break }
            out.beats[i].end += 0.25
        }
        out.hashtags = Array(out.hashtags.map { $0.hasPrefix("#") ? $0 : "#" + $0 }.prefix(8))
        if vertical, !out.hashtags.contains(where: { $0.caseInsensitiveCompare("#Shorts") == .orderedSame }) { out.hashtags.insert("#Shorts", at: 0) }
        return out
    }

    /// One vision call; one retry with the validation error if the JSON is malformed or breaks the rules.
    static func write(client: LLMClient, cost: CostTracker, settings: AppSettings, options: StoryOptions,
                      moments: [StoryMoment], words: [Word], duration: Double, profile: StyleProfile? = nil) async throws -> Storyboard {
        var content: [LLMContent] = [.text(StoryConfig.userIntro(options, duration: duration))]
        // Long videos: only send speech near the candidate moments.
        let relevant = words.count > 1500 ? words.filter { w in moments.contains { w.start >= $0.start - 10 && w.end <= $0.end + 10 } } : words
        content.append(.text("Commentary transcript (seconds):\n" + (relevant.isEmpty ? "(no speech detected)" : relevant.timestampedText)))
        for m in moments {
            content.append(.text("Candidate \(m.index): \(String(format: "%.1f", m.start))–\(String(format: "%.1f", m.end)) s · loudness \(m.loudness) · motion \(m.motion) · scene changes \(m.scene) · speech \(m.speech)"))
            for f in m.frames { if let d = try? Data(contentsOf: URL(fileURLWithPath: f)) { content.append(.jpeg(d)) } }
        }
        content.append(.text("Return the storyboard JSON now."))

        var problem = ""
        for attempt in 0..<2 {
            guard await cost.canSpend(budget: settings.dailyBudgetUSD) else { throw ClipForgeError("Daily API budget reached. Raise it in Settings → Highlights.") }
            let msg = attempt == 0 ? content : content + [.text("Your previous storyboard was rejected: \(problem). Return only the corrected JSON object.")]
            let system = StoryConfig.system(for: options.style) + (profile.map { EditPlanner.guide($0, intensity: options.intensity) } ?? "")
            let r = try await client.complete(model: StoryConfig.model, system: system, content: msg,
                                              maxTokens: StoryConfig.maxTokens, effort: StoryConfig.effort)
            await cost.record(r.usage, price: settings.prices[StoryConfig.model])
            guard let sb = parse(r.text) else {
                Log.ai.error("Unparseable plan (stop \(r.text.count) chars): \(String(r.text.prefix(300)), privacy: .public) … \(String(r.text.suffix(200)), privacy: .public)")
                problem = "it was not a valid JSON object in the required shape"; continue
            }
            if let err = validate(sb, moments: moments, duration: duration, style: options.style) { problem = err; continue }
            return fit(sb, target: options.targetSeconds, moments: moments, duration: duration, style: options.style, vertical: options.format == .vertical)
        }
        throw ClipForgeError("Claude returned an invalid edit plan twice (\(problem)). Try again, or pick a different length or style.")
    }
}
