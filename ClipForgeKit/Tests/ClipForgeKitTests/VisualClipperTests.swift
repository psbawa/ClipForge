import Foundation
import Testing
@testable import ClipForgeKit

private func scan(hud: [(Double, String)] = [], audio: [(Double, String, Double)] = [], duration: Double = 120) -> GameplayScanner.Scan {
    var s = GameplayScanner.Scan()
    s.hud = hud.map { (time: $0.0, text: $0.1) }; s.audio = audio.map { (time: $0.0, label: $0.1, confidence: $0.2) }; s.duration = duration
    return s
}

@Test func hudCountsOnlyNewAppearancesAndPopups() {
    let fps = GenreConfig.profile("fps")
    // An objective banner saying "ELIMINATE" is not a kill; "ELIMINATED" visible for 3 s counts once; reappearing later counts again.
    let s = scan(hud: [(10.5, "Eliminate the target"), (20.5, "ELIMINATED"), (21.5, "Eliminated"), (22.5, "ELIMINATED"),
                       (40.5, "ELIMINATED"), (41.5, "+100"), (50.5, "Victory Royale"), (60.5, "Ammo 30")])
    let ev = GameplayScanner.events(s, genre: fps)
    #expect(ev.filter { $0.label == "ELIMINATED" }.map(\.time) == [20.5, 40.5])
    #expect(ev.contains { $0.label == "+POINTS" && $0.time == 41.5 })
    #expect(ev.contains { $0.label == "VICTORY" && $0.weight == 2 })
    #expect(!ev.contains { $0.time == 10.5 || $0.time == 60.5 })
    // Short keywords match whole words only: "KO" must not fire inside "KNOCKOUT CITY" words like "KOALA".
    #expect(GameplayScanner.events(scan(hud: [(5, "KOALA")]), genre: GenreConfig.profile("fighting")).isEmpty)
    #expect(GameplayScanner.events(scan(hud: [(5, "K.O.")]), genre: GenreConfig.profile("fighting")).count == 1)
}

@Test func soundEventsMergeAndGenreIsDetected() {
    let gun = (0..<20).map { (Double($0) * 0.4 + 30, "gunshot_gunfire", 0.9) }        // 8 s of continuous fire
    let s = scan(audio: gun + [(31, "boom", 0.8), (90, "cheering", 0.7)])
    let ev = GameplayScanner.events(s, genre: GenreConfig.profile("fps"))
    #expect(ev.filter { $0.label == "gunshot_gunfire" }.count <= 8)                    // merged within 1 s
    #expect(ev.contains { $0.label == "boom" } && ev.contains { $0.label == "cheering" })
    #expect(GameplayScanner.genre(s, setting: "auto").id == "fps")
    #expect(GameplayScanner.genre(s, setting: "racing").id == "racing")              // manual override wins
    #expect(GameplayScanner.genre(scan(audio: [(5, "screaming", 0.9), (40, "screaming", 0.9), (80, "screaming", 0.9)]), setting: "auto").id == "horror")
    #expect(GameplayScanner.genre(scan(), setting: "auto").id == "other")
    #expect(GameplayScanner.summary(ev, from: 29, to: 40).contains("gunshot gunfire ×"))
}

@Test func eventsLiftTheRightWindow() {
    // Flat signals everywhere; only HUD + sound events at 200–206 s.
    let n = 400
    let sig = StorySignals(loudness: Array(repeating: -20, count: n), motion: (0..<n).map { Double($0 % 7) / 100 }, scene: Array(repeating: 0, count: n))
    let ev = [GameEvent(time: 201, source: .hud, label: "DOUBLE KILL", weight: 1.5), GameEvent(time: 203, source: .hud, label: "ELIMINATED", weight: 1),
              GameEvent(time: 202, source: .audio, label: "boom", weight: 0.9)]
    let w = MomentFinder.windows(sig, words: [], transcriptRatings: [], duration: Double(n), events: ev, weights: GenreConfig.profile("fps").weights)
    let best = MomentFinder.top(w, count: 1)[0]
    #expect(best.start <= 201 && best.end >= 203)
    #expect(best.peak >= 200 && best.peak <= 204)
    #expect(best.events.contains("DOUBLE KILL"))
    #expect((best.signals["hud"] ?? 0) > 0.9)
}

final class TriageLLM: LLMClient, @unchecked Sendable {
    let reply: String; var models: [String] = []
    init(_ r: String) { reply = r }
    func complete(model: String, system: String, content: [LLMContent], maxTokens: Int, effort: String) async throws -> LLMResponse {
        models.append(model)
        return LLMResponse(text: reply, usage: LLMUsage(input: 1000, output: 100))
    }
}

@Test func triageShortlistsWithHaikuAndFallsBackOnGarbage() async throws {
    let cands = (1...12).map { i in MomentCandidate(index: i, start: Double(i) * 40, end: Double(i) * 40 + 30, peak: Double(i) * 40 + 10,
                                                   signals: [:], preScore: Double(i) / 12) }
    // Haiku loves the two lowest-signal windows (menus scored high by signals would be dropped the other way round).
    let others = (3...12).map { #"{"index": \#($0), "score": 10, "label": "walking"}"# }.joined(separator: ",")
    let llm = TriageLLM(#"[{"index": 1, "score": 100, "label": "triple kill"}, {"index": 2, "score": 95, "label": "clutch"}, "# + others + "]")
    let short = try await MomentFinder.triage(cands, count: 4, client: llm, cost: freshTracker(), settings: AppSettings())
    #expect(llm.models == [SelectionConfig.triageModel])
    #expect(short.count == 4 && short.map(\.index) == [1, 2, 3, 4])                 // re-indexed in time order
    #expect(short.contains { $0.start == 40 && $0.triageLabel == "triple kill" })
    #expect(short.contains { $0.start == 480 })                                     // highest-signal window still in
    let fallback = try await MomentFinder.triage(cands, count: 4, client: TriageLLM("sorry"), cost: freshTracker(), settings: AppSettings())
    #expect(fallback.map(\.start) == [360, 400, 440, 480])                          // signals only
}

/// Claude's whole-video watch cells become a per-second signal that can lift a quiet but visually great moment.
@Test func watchedCellsLiftAQuietVisualMoment() {
    #expect(VideoWatcher.spacing(600) == 4 && VideoWatcher.spacing(10800) == 20)     // long videos widen spacing, capped cost
    let cells = [VideoWatcher.Cell(t: 302, score: 9, label: "the finished city lights up"), VideoWatcher.Cell(t: 50, score: 2, label: "menu")]
    let watch = VideoWatcher.signal(cells, duration: 400)
    #expect(watch[300] == 0.9 && watch[303] == 0.9 && watch[50] == 0.2 && watch[200] == 0)
    // Flat audio/motion everywhere: without the watch signal nothing stands out; with it, the window at ~300 s wins.
    let n = 400
    let sig = StorySignals(loudness: Array(repeating: -25, count: n), motion: (0..<n).map { Double($0 % 5) }, scene: Array(repeating: 0, count: n))
    let w = MomentFinder.windows(sig, words: [], transcriptRatings: [], duration: Double(n), watch: watch)
    let best = MomentFinder.top(w, count: 1)[0]
    #expect(best.start <= 302 && best.end >= 302 && (best.signals["watch"] ?? 0) > 0.9)
    #expect(VideoWatcher.summary(cells, from: 290, to: 320) == "5:02 the finished city lights up (9)")
}
