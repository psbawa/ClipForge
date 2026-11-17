import Foundation

public enum HighlightError: Error, Equatable { case budgetReached }

/// Two-stage highlight detection: a fast model scores overlapping transcript windows,
/// a stronger model ranks and writes metadata only for candidates above a threshold.
public actor HighlightService {
    let client: LLMClient
    let cost: CostTracker
    public private(set) var candidates: [Highlight] = []

    public init(client: LLMClient, cost: CostTracker) { self.client = client; self.cost = cost }

    public func reset(_ existing: [Highlight] = []) { candidates = existing }

    /// Stage A on the window ending at `end`. Returns the merged candidate list.
    @discardableResult
    public func scoreWindow(_ words: [Word], end: Double, settings s: AppSettings, window length: Double? = nil) async throws -> [Highlight] {
        let window = words.slice(end - (length ?? s.windowSeconds), end)
        guard window.count > 20 else { return candidates }
        let user = "Transcript window \(Int(window.first!.start))s–\(Int(window.last!.end))s:\n<transcript>\n\(window.timestampedText)\n</transcript>\nReturn the JSON array now."
        let raw: [RawCandidate] = try await ask(model: s.fastModel, system: Prompts.stageA, user: user, effort: "low", settings: s)
        // Reject times the model invented outside the window it was shown.
        let (lo, hi) = (window.first!.start - 1, window.last!.end + 1)
        let found = raw.filter { $0.start >= lo && $0.end <= hi }.map { Highlight(start: $0.start, end: $0.end, title: $0.title, hook: $0.hook ?? "", score: $0.score, reason: $0.reason ?? "") }
            .compactMap { HighlightLogic.normalize($0, words: words, settings: s) }
        candidates = HighlightLogic.merge(candidates, found)
        return candidates
    }

    /// Stage B for unranked candidates at or above the threshold.
    @discardableResult
    /// `force` ranks those candidates even below the threshold (used to fill a video's minimum clip count).
    public func rank(_ words: [Word], settings s: AppSettings, force: Set<UUID> = []) async throws -> [Highlight] {
        let todo = candidates.filter { $0.finalScore == nil && ($0.score >= s.stageBThreshold || force.contains($0.id)) }
        guard !todo.isEmpty else { return [] }
        let list = todo.enumerated().map { i, h in
            "<candidate index=\"\(i)\" start=\"\(h.start)\" end=\"\(h.end)\" stage_a_score=\"\(h.score)\">\n\(words.slice(h.start, h.end).joinedText)\n</candidate>"
        }.joined(separator: "\n")
        let ranked: [RankedCandidate] = try await ask(model: s.strongModel, system: Prompts.stageB, user: list + "\nReturn the JSON array now.", effort: "medium", settings: s)
        var out: [Highlight] = []
        for r in ranked where todo.indices.contains(r.index) {
            guard let i = candidates.firstIndex(where: { $0.id == todo[r.index].id }) else { continue }
            candidates[i].finalScore = r.score
            candidates[i].title = HighlightLogic.shortsTitle(r.title)
            candidates[i].description = r.description
            candidates[i].tags = Array(r.tags.prefix(15))
            out.append(candidates[i])
        }
        return out
    }

    /// One call + one retry on malformed JSON. Bad output never throws past here; it yields [].
    func ask<T: Decodable & Validatable>(model: String, system: String, user: String, effort: String, settings s: AppSettings) async throws -> [T] {
        var prompt = user
        for attempt in 0..<2 {
            guard await cost.canSpend(budget: s.dailyBudgetUSD) else { throw HighlightError.budgetReached }
            let r = try await client.complete(model: model, system: system, user: prompt, maxTokens: 4000, effort: effort)
            await cost.record(r.usage, price: s.prices[model])
            if let items: [T] = HighlightLogic.decode(r.text) { return items }
            Log.ai.warning("Malformed JSON from \(model, privacy: .public) (attempt \(attempt + 1))")
            prompt = user + "\n\nYour previous reply was not a valid JSON array matching the schema. Reply with ONLY the JSON array, no prose, no code fences."
        }
        return []
    }
}

protocol Validatable { var isValid: Bool { get } }

struct RawCandidate: Decodable, Validatable {
    var start: Double, end: Double, title: String, hook: String?, score: Int, reason: String?
    var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end > start && (0...100).contains(score) && !title.isEmpty }
}

struct RankedCandidate: Decodable, Validatable {
    var index: Int, score: Int, title: String, description: String, tags: [String]
    var isValid: Bool { index >= 0 && (0...100).contains(score) && !title.isEmpty }
}

public enum HighlightLogic {
    /// Extracts the outermost JSON array, decodes it, drops invalid items. nil = unparseable.
    static func decode<T: Decodable & Validatable>(_ text: String) -> [T]? {
        guard let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b else { return nil }
        guard let items = try? JSONDecoder().decode([Lossy<T>].self, from: Data(text[a...b].utf8)) else { return nil }
        return items.compactMap(\.value).filter(\.isValid)
    }

    static let pauseGap = 0.5      // a pause this long between words is a natural boundary
    static let lookaround = 6.0    // how far a boundary may be from the scored moment

    /// Snap to natural boundaries — sentence ends, pauses (≥ 0.5 s) and scene cuts — padded into the silence,
    /// never splitting a word and never cutting into the scored moment. nil if the transcript can't support a clip.
    public static func normalize(_ h: Highlight, words: [Word], settings s: AppSettings, cuts: [Double] = []) -> Highlight? {
        let core = (start: h.start, end: h.end)
        guard core.end > core.start, !words.isEmpty, let firstIdx = words.firstIndex(where: { $0.end > core.start }) else { return nil }
        func startsUnit(_ i: Int) -> Bool { i == 0 || words[i - 1].endsSentence || words[i].start - words[i - 1].end >= pauseGap }
        func endsUnit(_ i: Int) -> Bool { i == words.count - 1 || words[i].endsSentence || words[i + 1].start - words[i].end >= pauseGap }

        // Start: the latest sentence/pause start at or before the moment (within reach), else the word it starts in.
        var si = firstIdx, k = firstIdx
        while k > 0, !startsUnit(k), core.start - words[k - 1].start <= lookaround { k -= 1 }
        if startsUnit(k) { si = k }
        let prevEnd = si > 0 ? words[si - 1].end : 0
        var start = words[si].start
        if let c = cuts.filter({ $0 <= start && start - $0 <= 1.5 && $0 >= prevEnd }).max() { start = c }
        else { start = max(start - s.preRoll, prevEnd + 0.05, 0) }
        start = min(start, core.start)

        // End: the first sentence/pause end after the moment (and after the minimum length), within reach.
        let target = max(core.end, start + s.minClipSeconds)
        var ei = max(si, (words.lastIndex { $0.start < target } ?? si)), j = ei
        while j < words.count - 1, !endsUnit(j), words[j].end - target <= lookaround { j += 1 }
        if endsUnit(j) { ei = j }
        let nextStart = ei + 1 < words.count ? words[ei + 1].start : .infinity
        var end = max(words[ei].end, core.end)
        if let c = cuts.filter({ $0 >= end && $0 - end <= 1.5 && $0 <= nextStart }).min() { end = c }
        else { end = min(end + s.postRoll, nextStart - 0.05) }
        end = max(end, core.end)
        // Too short and the next speech is far off: run into the music/silence, ending on a scene cut if one is close.
        if end - start < s.minClipSeconds, nextStart - 0.05 > end {
            end = min(start + s.minClipSeconds, nextStart - 0.05)
            if let c = cuts.filter({ abs($0 - end) <= 1.5 && $0 >= max(core.end, start + s.minClipSeconds - 1.5) && $0 < nextStart }).min(by: { abs($0 - end) < abs($1 - end) }) { end = c }
        }
        guard end - start >= min(s.minClipSeconds, core.end - core.start) else { return nil }
        // The scored moment wins over the preferred max length; only the 3-minute Shorts limit is absolute.
        end = min(end, start + s.hardMaxSeconds)

        var out = h
        out.start = start
        out.end = end
        out.coreStart = core.start
        out.coreEnd = min(core.end, end)
        return out
    }

    /// Overlapping windows rediscover the same moment; keep one (highest score), pass through new ones.
    public static func merge(_ existing: [Highlight], _ new: [Highlight]) -> [Highlight] {
        var all = existing
        for n in new {
            if let i = all.firstIndex(where: { overlapRatio($0, n) > 0.5 }) {
                if n.score > all[i].score {
                    let keepID = all[i].id, ranked = all[i].finalScore != nil ? all[i] : nil
                    all[i] = n
                    all[i].id = keepID
                    if let ranked { all[i].finalScore = ranked.finalScore; all[i].title = ranked.title; all[i].description = ranked.description; all[i].tags = ranked.tags }
                }
            } else {
                all.append(n)
            }
        }
        return all.sorted { $0.start < $1.start }
    }

    /// Overlap as a fraction of the shorter clip.
    public static func overlapRatio(_ a: Highlight, _ b: Highlight) -> Double {
        let o = min(a.end, b.end) - max(a.start, b.start)
        return o <= 0 ? 0 : o / max(min(a.duration, b.duration), 0.001)
    }

    /// YouTube titles max 100 chars; add #Shorts when it fits.
    public static func shortsTitle(_ t: String) -> String {
        let base = String(t.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "").prefix(100))
        return base.localizedCaseInsensitiveContains("#shorts") || base.count + 8 > 100 ? base : base + " #Shorts"
    }
}

/// Decodes one array element without failing the whole array.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from d: Decoder) throws { value = try? T(from: d) }
}

enum Prompts {
    static let stageA = """
    You are a highlight scout for a live-stream clipping tool. You read a slice of a stream transcript and find the moments most likely to work as stand-alone YouTube Shorts (vertical, under 60 seconds).

    Input format: each transcript line starts with a timestamp in seconds on the stream timeline, like "[812.4] text". Timestamps are absolute; use them exactly as given. The window overlaps with previous windows, so some moments may have been reported before; report them again if they are still among the best in this window.

    What makes a great Short:
    - A clear hook in the first 3 seconds: a surprising claim, a strong reaction, a question, a punchline setup.
    - A self-contained arc: the viewer understands it without the rest of the stream.
    - Emotional peaks: laughter, excitement, frustration, disbelief, a big win or a big fail.
    - Quotable lines, hot takes, useful tips explained concisely, or a story with a payoff.
    - Ends on a payoff or a natural sentence end, not mid-thought.

    Avoid: housekeeping (sponsor reads, "hit subscribe", schedule announcements), dead air, long technical setup with no payoff, reading chat names, moments that need visual context the transcript cannot confirm, and anything that would be harmful, hateful or misleading if taken out of context.

    Scoring (integer 0-100): 90+ = would clearly go viral; 75-89 = strong clip; 60-74 = decent; below 60 = do not bother. Be calibrated and stingy with scores: most windows contain zero or one moment above 75. Low scores are fine — honesty matters more than enthusiasm.

    Length: aim for 20-59 seconds. Start a little before the hook so it has context; end right after the payoff.

    Output: ONLY a JSON array (no prose, no code fences). Always return the 1-3 strongest moments in this window, best first, even if none is exceptional — the editor decides what to cut, so give them your best picks with honest scores. Return [] only if the window has no usable speech or lyrics at all. Each item:
    {"start": <seconds, number>, "end": <seconds, number>, "title": "<punchy title, max 70 chars, no hashtags>", "hook": "<the opening line or idea that grabs attention>", "score": <0-100 integer>, "reason": "<one sentence on why this works>"}

    Rules: start < end; both inside the window; numbers not strings; double quotes; no trailing commas; no extra keys.
    """

    static let stageB = """
    You are the senior editor for a YouTube Shorts channel. You receive candidate clips (transcripts with timings) that a first-pass scout flagged. Re-score each one independently and calibrated (0-100) for how well it would perform as a stand-alone Short: hook strength in the first 3 seconds, self-contained story, emotional or informational payoff, rewatchability. Penalize anything that depends on missing visual context or could mislead when taken out of context.

    For each candidate write publish-ready metadata:
    - title: max 70 characters, curiosity-driven but accurate, no clickbait lies, no hashtags.
    - description: 1-3 short sentences that set up the moment, then a blank line, then 3-5 relevant hashtags ending with #Shorts.
    - tags: 5-12 lowercase keyword tags, no '#'.

    Output ONLY a JSON array (no prose, no code fences), one item per candidate, using the candidate's index:
    [{"index": 0, "score": 82, "title": "...", "description": "...", "tags": ["...", "..."]}]
    """
}
