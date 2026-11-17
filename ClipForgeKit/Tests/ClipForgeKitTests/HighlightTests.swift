import Foundation
import Testing
@testable import ClipForgeKit

/// Scripted LLM: returns queued replies in order, records every call.
final class MockLLM: LLMClient, @unchecked Sendable {
    var replies: [String]
    var calls: [(model: String, user: String)] = []
    let lock = NSLock()
    init(_ replies: [String]) { self.replies = replies }
    func complete(model: String, system: String, content: [LLMContent], maxTokens: Int, effort: String) async throws -> LLMResponse {
        let user = content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
        return lock.withLock {
            calls.append((model, user))
            return LLMResponse(text: replies.isEmpty ? "[]" : replies.removeFirst(), usage: LLMUsage(input: 1000, output: 200, cacheRead: 2000))
        }
    }
}

/// ~7 minutes of fake stream: one 3 s sentence every 4 s.
let sampleTranscript: [Word] = (0..<105).flatMap { i -> [Word] in
    let t = Double(i) * 4
    let text = i == 50 ? "No way did that just happen, that is the craziest play I have ever seen." : "We keep going with the run here."
    let parts = text.split(separator: " ").map(String.init)
    let step = 3.0 / Double(parts.count)
    return parts.enumerated().map { j, w in Word(w, t + Double(j) * step, t + Double(j + 1) * step) }
}

func freshTracker() -> CostTracker { CostTracker(defaults: UserDefaults(suiteName: UUID().uuidString)!) }

@Test func decodeHandlesFencesAndDropsInvalidItems() {
    let text = """
    Here you go:
    ```json
    [{"start": 10, "end": 40, "title": "Good", "hook": "h", "score": 80, "reason": "r"},
     {"start": 50, "end": 20, "title": "Backwards", "score": 90},
     {"start": "x", "end": 1, "title": "Bad types", "score": 70},
     {"start": 1, "end": 30, "title": "Out of range", "score": 140}]
    ```
    """
    let items: [RawCandidate]? = HighlightLogic.decode(text)
    #expect(items?.map(\.title) == ["Good"])
    let none: [RawCandidate]? = HighlightLogic.decode("not json at all")
    #expect(none == nil)
}

@Test func normalizeSnapsToNaturalBoundaries() throws {
    let s = AppSettings()
    // Model returns a 5 s range starting mid-sentence (sentences: 3 s of speech every 4 s).
    let h = Highlight(start: 201.5, end: 206, title: "t", hook: "", score: 90, reason: "")
    let n = try #require(HighlightLogic.normalize(h, words: sampleTranscript, settings: s))
    #expect(n.start > 199 && n.start <= 200)              // padded into the pause before the sentence, not into the previous one
    #expect(n.duration >= s.minClipSeconds && n.duration <= s.maxClipSeconds + 1)
    #expect(sampleTranscript.contains { abs(n.end - $0.end) <= s.postRoll + 0.01 && $0.endsSentence })  // ends after a sentence
    #expect(!sampleTranscript.contains { $0.start < n.start && $0.end > n.start })   // never mid-word
    #expect(!sampleTranscript.contains { $0.start < n.end && $0.end > n.end })
    #expect(n.coreStart == 201.5 && n.coreEnd == 206)

    // A scored moment longer than the preferred max is kept whole (only the 3-minute limit applies).
    let long = Highlight(start: 20, end: 110, title: "t", hook: "", score: 90, reason: "")
    let l = try #require(HighlightLogic.normalize(long, words: sampleTranscript, settings: s))
    #expect(l.start <= 20 && l.end >= 110 && l.duration <= s.hardMaxSeconds)

    // A scene cut just before the sentence becomes the start.
    let c = try #require(HighlightLogic.normalize(h, words: sampleTranscript, settings: s, cuts: [199.6]))
    #expect(c.start == 199.6)
}

@Test func normalizeUsesPausesAndNeverSplitsWords() throws {
    // One long run-on sentence (no punctuation) with a 0.8 s pause at 30 s.
    var w: [Word] = []
    for i in 0..<140 { let t = Double(i) * 0.5; w.append(Word("w\(i)", t, t + 0.4)) }
    w = w.map { $0.start >= 30 ? Word($0.text, $0.start + 0.8, $0.end + 0.8) : $0 }
    let h = Highlight(start: 31.3, end: 40, title: "t", hook: "", score: 90, reason: "")
    let n = try #require(HighlightLogic.normalize(h, words: w, settings: AppSettings()))
    #expect(n.start >= 29.9 && n.start <= 30.8)           // starts in the pause, right before speech resumes
    #expect(!w.contains { $0.start < n.start && $0.end > n.start } && !w.contains { $0.start < n.end && $0.end > n.end })
}

@Test func mergeDedupesOverlappingWindows() {
    let a = Highlight(start: 100, end: 130, title: "A", hook: "", score: 70, reason: "")
    let b = Highlight(start: 102, end: 128, title: "B", hook: "", score: 85, reason: "")
    let c = Highlight(start: 300, end: 330, title: "C", hook: "", score: 60, reason: "")
    let m = HighlightLogic.merge([a], [b, c])
    #expect(m.count == 2)
    #expect(m[0].id == a.id && m[0].score == 85 && m[0].title == "B")
}

@Test func stageARetriesOnceOnMalformedJSON() async throws {
    let good = #"[{"start": 200, "end": 225, "title": "Craziest play", "hook": "No way", "score": 88, "reason": "peak"}]"#
    let llm = MockLLM(["Sure! Here are the highlights: {oops", good])
    let svc = HighlightService(client: llm, cost: freshTracker())
    let c = try await svc.scoreWindow(sampleTranscript, end: 420, settings: AppSettings())
    #expect(llm.calls.count == 2)
    #expect(llm.calls.allSatisfy { $0.model == "claude-haiku-5-5" })
    #expect(c.count == 1 && c[0].score == 88)
}

@Test func stageARejectsTimesOutsideTheWindow() async throws {
    let llm = MockLLM([#"[{"start": 500, "end": 530, "title": "Future", "score": 95, "reason": "r"}]"#])
    let svc = HighlightService(client: llm, cost: freshTracker())
    #expect(try await svc.scoreWindow(sampleTranscript, end: 300, settings: AppSettings()).isEmpty)
}

@Test func stageANeverCrashesOnGarbage() async throws {
    let llm = MockLLM(["garbage", "{\"still\": \"bad\"}"])
    let svc = HighlightService(client: llm, cost: freshTracker())
    let c = try await svc.scoreWindow(sampleTranscript, end: 420, settings: AppSettings())
    #expect(c.isEmpty && llm.calls.count == 2)
}

@Test func stageBOnlyRanksCandidatesAboveThreshold() async throws {
    let a = #"[{"start": 200, "end": 225, "title": "Hot", "score": 88, "reason": "r"}, {"start": 40, "end": 65, "title": "Meh", "score": 50, "reason": "r"}]"#
    let b = #"[{"index": 0, "score": 91, "title": "The craziest play ever", "description": "Wow.\n\n#gaming #Shorts", "tags": ["gaming"]}]"#
    let llm = MockLLM([a, b])
    let svc = HighlightService(client: llm, cost: freshTracker())
    try await svc.scoreWindow(sampleTranscript, end: 420, settings: AppSettings())
    let ranked = try await svc.rank(sampleTranscript, settings: AppSettings())
    #expect(llm.calls.count == 2 && llm.calls[1].model == "claude-sonnet-5-5")
    #expect(llm.calls[1].user.contains("index=\"0\"") && !llm.calls[1].user.contains("index=\"1\""))
    #expect(ranked.count == 1 && ranked[0].finalScore == 91 && ranked[0].title.hasSuffix("#Shorts"))
    // Already ranked → no second Stage B call.
    _ = try await svc.rank(sampleTranscript, settings: AppSettings())
    #expect(llm.calls.count == 2)
}

@Test func costTrackerMathAndBudgetCap() async throws {
    let p = ModelPrice(1.0, 5.0)
    let c = CostTracker.cost(LLMUsage(input: 1_000_000, output: 100_000, cacheWrite: 1_000_000, cacheRead: 1_000_000), p)
    #expect(abs(c - (1 + 1.25 + 0.1 + 0.5)) < 1e-9)

    let tracker = freshTracker()
    var s = AppSettings()
    s.dailyBudgetUSD = 0.0001
    s.prices["claude-haiku-5-5"] = p
    let llm = MockLLM([#"[]"#])
    let svc = HighlightService(client: llm, cost: tracker)
    try await svc.scoreWindow(sampleTranscript, end: 420, settings: s)  // spends > budget
    await #expect(throws: HighlightError.budgetReached) { try await svc.scoreWindow(sampleTranscript, end: 420, settings: s) }
    #expect(llm.calls.count == 1)
    #expect(await tracker.sessionCost > 0.0001)
}

@Test func requestBodyCachesStaticSystemPrompt() throws {
    let b = AnthropicClient.body(model: "m", system: "S", content: [.text("U")], maxTokens: 10, effort: "low")
    let sys = try #require(b["system"] as? [[String: Any]])
    #expect((sys[0]["cache_control"] as? [String: String]) == ["type": "ephemeral"])
    let usage = try AnthropicClient.parse(Data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"[]"}],"usage":{"input_tokens":5,"output_tokens":2,"cache_read_input_tokens":900}}"#.utf8))
    #expect(usage.text == "[]" && usage.usage.cacheRead == 900)
}

/// Regression (real transcript): hyphenated words were split ("merry -go -round") and speaker dashes leaked ("- Okay.").
@Test func whisperPiecesJoinIntoRealWords() {
    let p: [(text: String, start: Double, end: Double)] = [
        (" Uh,", 0, 0.3), (" merry", 0.3, 0.6), ("-go", 0.6, 0.8), ("-round", 0.8, 1.1), ("?", 1.1, 1.2),
        (" - Okay.", 2, 2.4), (" co", 3, 3.2), ("-founders", 3.2, 3.8), (" It", 4, 4.1), ("'s", 4.1, 4.2), (" 1,", 4.3, 4.5), ("000", 4.5, 4.8),
        (" -", 5, 5.1), (" Now", 5.1, 5.4), ("<|endoftext|>", 6, 6), (" [music]", 6, 7), (" done.", 7, 7.5),
    ]
    let w = WhisperTranscriber.assemble(p)
    #expect(w.map(\.text) == ["Uh,", "merry-go-round?", "Okay.", "co-founders", "It's", "1,000", "Now", "done."])
    #expect(w[1].start == 0.3 && w[1].end == 1.2)        // merged word keeps the full span
}

/// Long unpunctuated runs (a large-v3 turbo quirk) get sentence ends at pauses so clip edges and captions still work.
@Test func unpunctuatedRunsGetSentencesAtPauses() {
    var t = 0.0
    func w(_ s: String, gap: Double = 0.05) -> (text: String, start: Double, end: Double) { defer { t += 0.3 + gap }; return (" " + s, t, t + 0.3) }
    let words = "so for that we had to consult with an expert on the playground design how's it going".split(separator: " ").enumerated().map { i, s in w(String(s), gap: i == 13 ? 0.6 : 0.05) }
        + [w("i"), w("think"), w("so.")]
    let out = WhisperTranscriber.assemble(words).map(\.text).joined(separator: " ")
    #expect(out == "So for that we had to consult with an expert on the playground design. How's it going I think so.")
    // Already-punctuated speech is left alone.
    #expect(WhisperTranscriber.assemble([w("Hello"), w("there.", gap: 1), w("Yes.")]).map(\.text) == ["Hello", "there.", "Yes."])
}
