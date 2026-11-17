import AppKit
import Foundation
import ImageIO

/// One Claude (vision) call plans the full vlog and/or the shorts as edit decision lists over the imported files.
enum VlogPlanner {
    static let model = "claude-sonnet-5-5"
    static let maxImages = 60
    static let purposes: Set<String> = ["hook", "title", "talk", "broll", "montage", "moment", "outro", "payoff", "climax", "buildup"]

    static let system = """
    You are a travel vlog editor. You get the trip's footage as a numbered list of usable shots (file id, time ranges that are usable,
    capture time, chapter, whether the vlogger talks to camera and what they say) plus one frame per shot, and the creator's settings.

    FULL VLOG (if requested), as one beat list:
    - Cold open: 1–3 of the most striking moments (a teaser), then a "title" beat (a scenic shot, caption = trip title).
    - Then chapters in trip order. Each chapter opens with a scenic establishing beat whose caption is the chapter title (e.g. "Day 2 · Goa").
    - Keep talking-to-camera parts intact (purpose "talk"): start and end on sentence boundaries, never mid-sentence. Cover/fill between
      talking parts with B-roll (scenery, food, details, people): purpose "broll" (3–7 s each).
    - Vary pacing: quick "montage" runs (1.5–3 s beats) for scenery/activities, slower beats for key experiences.
    - End on a sunset / reflection / outro beat (purpose "outro").
    - Photos (duration 0 in the list) can be used as 3–5 s beats; set start 0 and end to the beat length.
    SHORTS (if requested): each is a self-contained story or theme (e.g. "Best street food", "Sunset montage", "Funniest moment"),
    with a hook in the first 1–2 s, beats from anywhere in the trip, and short captions.

    Rules: every beat uses an id from the list and a start/end inside one of that shot's usable ranges (photos: 0–5). No beat uses the
    same footage twice within one edit. Captions max 6 words (chapter/title cards may be the chapter title). Follow the creator's
    direction and the vibe. Only describe what the frames and transcripts support.

    Output ONLY this JSON object:
    {"title": "...", "description": "...", "hashtags": ["#travel"], "chapters": [{"index": 0, "title": "Day 1 · Arrival"}],
     "full": {"mood": "epic", "title": "...", "description": "...", "hashtags": [], "beats": [{"asset": "<id>", "start": 3.0, "end": 8.5, "purpose": "broll", "caption": "...", "chapter": 0}]},
     "shorts": [{"mood": "funny", "title": "...", "description": "...", "hashtags": ["#Shorts"], "beats": [...]}]}
    Use "full": null if no full vlog was requested, "shorts": [] if no shorts.
    """

    struct Answer: Decodable {
        struct Ch: Decodable { var index: Int; var title: String }
        var title: String?
        var chapters: [Ch]?
        var full: Storyboard?
        var shorts: [Storyboard]?
    }

    static func frame(_ a: VlogAsset, at t: Double, ffmpeg: URL, dir: URL) async -> Data? {
        let f = dir.appendingPathComponent("\(a.id)-\(Int(t * 10)).jpg")
        if !FileManager.default.fileExists(atPath: f.path) {
            if a.isPhoto {
                guard let src = CGImageSourceCreateWithURL(a.url as CFURL, nil),
                      let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 384,
                                                                            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                      let d = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { return nil }
                try? d.write(to: f)
            } else {
                try? await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-ss", String(format: "%.2f", t), "-i", a.proxyPath ?? a.path,
                                              "-frames:v", "1", "-vf", "scale=384:-2", "-q:v", "7", f.path])
            }
        }
        return try? Data(contentsOf: f)
    }

    static func plan(assets: [VlogAsset], chapters: [VlogChapter], options: VlogOptions, ffmpeg: URL, work: URL,
                     client: LLMClient, cost: CostTracker, settings: AppSettings) async throws -> (VlogPlan, [VlogChapter]) {
        let usable = assets.filter { $0.rejected == nil && !options.excluded.contains($0.id) }.sorted { $0.captured < $1.captured }
        guard !usable.isEmpty else { throw ClipForgeError("No usable footage left after dropping bad shots and exclusions.") }
        let goodSeconds = usable.map { $0.isPhoto ? 4 : $0.goodRanges.map { $0[1] - $0[0] }.reduce(0, +) }.reduce(0, +)
        let fullTarget = options.fullMinutes > 0 ? options.fullMinutes * 60 : min(15 * 60, max(60, goodSeconds * 0.35))
        let dir = work.appendingPathComponent("plan-frames")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Frames: highest-scoring shots first, but every chapter represented.
        var withImage = Set<String>()
        for ch in chapters { if let best = usable.filter({ ch.assetIDs.contains($0.id) }).max(by: { $0.score < $1.score }) { withImage.insert(best.id) } }
        for a in usable.sorted(by: { $0.score > $1.score }) where withImage.count < maxImages { withImage.insert(a.id) }

        var content: [LLMContent] = [.text("""
        Trip title: \(options.title.isEmpty ? "(suggest one)" : options.title). Places: \(options.places.isEmpty ? "—" : options.places). Vibe: \(options.vibe.label).
        Requested: \(options.output == .shorts ? "no full vlog" : "full vlog ≈ \(Int(fullTarget / 60)) min \(Int(fullTarget) % 60) s")\(options.output == .full ? ", no shorts" : ", \(options.shortsCount) shorts of ≈ \(Int(options.shortSeconds)) s").
        Direction: \(options.prompt.isEmpty ? "—" : options.prompt)
        Chapters: \(chapters.map { "\($0.index): \($0.title)" }.joined(separator: "; "))
        """)]
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d HH:mm"
        for a in usable {
            let ranges = a.isPhoto ? "photo" : a.goodRanges.map { String(format: "%.1f–%.1f", $0[0], $0[1]) }.joined(separator: ", ")
            let said = a.talking ? " · TALKS: \"" + String(a.words.joinedText.prefix(400)) + "\"" : ""
            content.append(.text("Shot \(a.id) · \(fmt.string(from: a.captured)) · chapter \(a.chapter ?? 0) · \(a.isPhoto ? "photo" : String(format: "%.0f s", a.duration)) · usable \(ranges) · score \(Int(a.score))\(said)"))
            if withImage.contains(a.id), let d = await frame(a, at: a.goodRanges.first.map { ($0[0] + $0[1]) / 2 } ?? 0, ffmpeg: ffmpeg, dir: dir) { content.append(.jpeg(d)) }
        }
        content.append(.text("Return the JSON now."))

        var problem = ""
        for attempt in 0..<2 {
            guard await cost.canSpend(budget: settings.dailyBudgetUSD) else { throw HighlightError.budgetReached }
            let msg = attempt == 0 ? content : content + [.text("Your previous answer was rejected: \(problem). Return only the corrected JSON object.")]
            let r = try await client.complete(model: model, system: system, content: msg, maxTokens: 16000, effort: "medium")
            await cost.record(r.usage, price: settings.prices[model])
            guard let a = r.text.firstIndex(of: "{"), let b = r.text.lastIndex(of: "}"),
                  let ans = try? JSONDecoder().decode(Answer.self, from: Data(r.text[a...b].utf8)) else { problem = "not a valid JSON object in the required shape"; continue }
            var plan = VlogPlan(full: options.output == .shorts ? nil : ans.full, shorts: options.output == .full ? [] : (ans.shorts ?? []))
            if let err = validate(&plan, assets: usable, options: options) { problem = err; continue }
            var named = chapters
            for c in ans.chapters ?? [] where named.indices.contains(c.index) { named[c.index].title = c.title }
            return (plan, named)
        }
        throw ClipForgeError("Claude returned an invalid vlog edit plan twice (\(problem)). Try again or change the options.")
    }

    /// Checks references and ranges, snaps talking beats to sentence boundaries, fixes photo lengths. nil = OK.
    static func validate(_ plan: inout VlogPlan, assets: [VlogAsset], options: VlogOptions) -> String? {
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        if options.output != .shorts, plan.full == nil { return "the full vlog plan is missing" }
        if options.output != .full, plan.shorts.count < max(1, options.shortsCount - 1) { return "expected \(options.shortsCount) shorts, got \(plan.shorts.count)" }
        func check(_ sb: inout Storyboard, label: String) -> String? {
            guard sb.beats.count >= 3 else { return "\(label) needs at least 3 beats" }
            for i in sb.beats.indices {
                let b = sb.beats[i]
                guard let id = b.asset, let a = byID[id] else { return "\(label) beat \(i + 1) uses unknown shot \(b.asset ?? "nil")" }
                if a.isPhoto {
                    sb.beats[i].start = 0; sb.beats[i].end = min(6, max(2, b.duration.isFinite && b.duration > 0 ? b.duration : 4))
                    continue
                }
                guard b.end > b.start, a.goodRanges.contains(where: { b.start >= $0[0] - 0.5 && b.end <= $0[1] + 0.5 }) else {
                    return "\(label) beat \(i + 1) (\(id) \(b.start)–\(b.end)) is outside the shot's usable ranges"
                }
                if !purposes.contains(b.purpose) { sb.beats[i].purpose = "broll" }
                if b.purpose == "talk", let snapped = snapToSentences(b.start, b.end, words: a.words) { (sb.beats[i].start, sb.beats[i].end) = snapped }
                if sb.beats[i].transition == nil { sb.beats[i].transition = "cut" }
            }
            return nil
        }
        if var f = plan.full { if let e = check(&f, label: "full vlog") { return e }; plan.full = f }
        for i in plan.shorts.indices { if let e = check(&plan.shorts[i], label: "short \(i + 1)") { return e } }
        return nil
    }

    /// Expand a talking range to whole sentences (never mid-sentence).
    static func snapToSentences(_ s: Double, _ e: Double, words: [Word]) -> (Double, Double)? {
        guard !words.isEmpty else { return nil }
        var si = words.firstIndex { $0.end > s } ?? 0
        while si > 0, !words[si - 1].endsSentence { si -= 1 }
        var ei = words.lastIndex { $0.start < e } ?? (words.count - 1)
        while ei < words.count - 1, !words[ei].endsSentence { ei += 1 }
        guard ei >= si else { return nil }
        return (max(0, words[si].start - 0.15), words[ei].end + 0.25)
    }
}
