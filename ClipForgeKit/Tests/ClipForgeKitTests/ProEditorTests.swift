import Foundation
import Testing
@testable import ClipForgeKit

@Test func seedProfilesLoadAndVersionsAreNeverOverwritten() throws {
    try StyleLibrary.$rootOverride.withValue(FileManager.default.temporaryDirectory.appendingPathComponent("styles-\(UUID())")) {
    let seeds = StyleLibrary.all()
    #expect(seeds.count == 10 && seeds.allSatisfy { $0.origin == "seed" })
    var p = try #require(StyleLibrary.profile("gaming-fast"))
    p.version = "2026-12-01"; p.pacing.avgShotSeconds = 1.2; p.origin = "trend-refresh"
    let a = try StyleLibrary.save(p), b = try StyleLibrary.save(p)
    #expect(a != b && FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    #expect(StyleLibrary.profile("gaming-fast")?.pacing.avgShotSeconds == 1.2)   // latest wins
    #expect(StyleLibrary.history("gaming-fast").count == 3)                      // seed + 2 saved, all kept
    }
}

func proBoard() -> Storyboard {
    var sb = board((0..<10).map { i in
        var b = beat(i == 0 ? "hook" : i == 9 ? "payoff" : i == 6 ? "climax" : "moment", Double(i * 20), Double(i * 20) + 2.5)
        b.zoom = 1.2; b.sfx = ["whoosh", "hit"]; b.transition = i == 0 ? nil : "flash"; b.speed = i == 6 ? 0.5 : 1
        return b
    })
    sb.mood = "hype"
    return sb
}

@Test func intensityScalesZoomsSfxAndAccents() throws {
    let fast = try #require(StyleLibrary.profile("gaming-fast")), calm = try #require(StyleLibrary.profile("aesthetic-vlog"))
    let lo = EditPlanner.applyIntensity(proBoard(), profile: fast, intensity: 0)
    let hi = EditPlanner.applyIntensity(proBoard(), profile: fast, intensity: 1)
    func zooms(_ s: Storyboard) -> Int { s.beats.filter { $0.zoom != nil }.count }
    func sfx(_ s: Storyboard) -> Int { s.beats.map { $0.sfx?.count ?? 0 }.reduce(0, +) }
    func accents(_ s: Storyboard) -> Int { s.beats.filter { $0.transition != nil && $0.transition != "cut" }.count }
    #expect(zooms(hi) > zooms(lo) && sfx(hi) >= sfx(lo) && accents(hi) > accents(lo))
    #expect(hi.beats.allSatisfy { ($0.zoom ?? 1) <= fast.motion.punchInScale + 0.05 + 1e-9 })
    let c = EditPlanner.applyIntensity(proBoard(), profile: calm, intensity: 1)
    #expect(c.beats.allSatisfy { $0.speed == 1 } && sfx(c) == 0)          // calm profile: no slow-mo ramps, no SFX kinds enabled
    #expect(c.beats.filter { $0.transition == "flash" }.isEmpty)           // flash isn't one of its accents
}

final class ScriptLLM: LLMClient, @unchecked Sendable {
    var replies: [String]; var calls = 0
    init(_ r: [String]) { replies = r }
    func complete(model: String, system: String, content: [LLMContent], maxTokens: Int, effort: String) async throws -> LLMResponse {
        calls += 1
        return LLMResponse(text: replies.isEmpty ? "" : replies.removeFirst(), usage: LLMUsage(input: 100, output: 50))
    }
}

@Test func autoPickAndCritique() async throws {
    let profiles = StyleLibrary.all()
    let p = try await EditPlanner.autoPick(StoryOptions(), words: [], profiles: profiles, client: ScriptLLM(["travel-cinematic"]), cost: freshTracker(), settings: AppSettings())
    #expect(p.id == "travel-cinematic")
    await #expect(throws: ClipForgeError.self) {
        _ = try await EditPlanner.autoPick(StoryOptions(), words: [], profiles: profiles, client: ScriptLLM(["no idea"]), cost: freshTracker(), settings: AppSettings())
    }
    // A valid revision is taken, with its notes.
    let sb = board([beat("hook", 45, 47.5), beat("buildup", 10, 18), beat("climax", 41, 49), beat("payoff", 72, 80)])
    var revised = sb; revised.beats[1].caption = "Sharper caption"
    let plan = String(decoding: try JSONEncoder().encode(revised), as: UTF8.self)
    let ok = try await EditPlanner.critique(sb, profile: profiles[0], options: StoryOptions(), moments: storyMoments, duration: 100,
                                            client: ScriptLLM(["{\"notes\": \"Tightened beat 2.\", \"plan\": \(plan)}"]), cost: freshTracker(), settings: AppSettings())
    #expect(ok.beats[1].caption == "Sharper caption" && ok.notes?.contains("Tightened") == true)
    // An unusable review twice keeps the validated plan and says so — never a random edit.
    let llm = ScriptLLM(["meh", "{\"notes\": \"x\", \"plan\": {\"broken\": true}}"])
    let kept = try await EditPlanner.critique(sb, profile: profiles[0], options: StoryOptions(), moments: storyMoments, duration: 100,
                                              client: llm, cost: freshTracker(), settings: AppSettings())
    #expect(kept.beats == sb.beats && kept.notes?.contains("review skipped") == true && llm.calls == 2)
}

@Test func sfxCuesAndPacingCuts() {
    var b = proBoard()
    b.beats = Array(b.beats.prefix(3))
    b.beats[1].sfx = ["whoosh"]; b.beats[2].sfx = ["riser", "hit"]; b.beats[0].sfx = nil
    let cues = EditPlanner.sfxCues(b)
    let s = StoryTimeline.starts(b.beats)
    #expect(cues.contains { $0.kind == .whoosh && abs($0.at - (s[1] - 0.2)) < 1e-9 })
    #expect(cues.contains { $0.kind == .hit && abs($0.at - s[2]) < 1e-9 })
    #expect(cues.contains { $0.kind == .riser && abs($0.at - (s[2] - SFXLibrary.length(.riser))) < 1e-9 })
    // Fillers and long pauses come out; normal speech stays.
    let w = [Word("So", 0, 0.3), Word("um", 0.4, 0.7), Word("this", 0.8, 1.1), Word("is", 3.0, 3.2), Word("it.", 3.3, 3.6)]
    let keep = try! #require(ClipService.pacingKeep(w, duration: 5))
    #expect(keep.count == 3 && abs(keep[1].0 - 0.7) < 1e-9 && abs(keep[1].1 - 1.35) < 1e-9 && abs(keep[2].0 - 2.75) < 1e-9)
    let r = ClipService.remap(w, keep: keep)
    #expect(r.map(\.text) == ["So", "this", "is", "it."] && abs(r[2].start - (3.0 - 0.3 - 1.4)) < 1e-9)   // um (0.3 s) + pause (1.4 s) removed
    #expect(ClipService.pacingKeep([Word("Fine", 0, 0.5), Word("speech.", 0.6, 1.0)], duration: 2) == nil)
}

extension PublishTests {
    @Test func trendRefreshSavesNewDatedVersionsFromOfficialData() async throws {
        try await StyleLibrary.$rootOverride.withValue(FileManager.default.temporaryDirectory.appendingPathComponent("styles-\(UUID())")) {
        #expect(TrendRefresh.seconds("PT1M5S") == 65 && TrendRefresh.seconds("PT2H") == 7200 && TrendRefresh.seconds("PT45S") == 45)
        let item = #"{"items":[{"snippet":{"title":"1 HP CLUTCH","tags":["warzone"]},"contentDetails":{"duration":"PT42S"},"statistics":{"viewCount":"900000"}}]}"#
        // 3 niches × 3 regions = 9 list calls.
        let session = MockHTTP.session(Array(repeating: (200, [:], item), count: 9))
        var updated = try #require(StyleLibrary.profile("gaming-fast"))
        updated.idealSeconds = 22; updated.notes = "Most-popular gaming shorts are ~40 s with number hooks."
        let enc = String(decoding: try JSONEncoder().encode([updated]), as: UTF8.self)
        let llm = ScriptLLM([enc, "[]", "[]"])
        let saved = try await TrendRefresh.run(auth: FakeAuth(), client: llm, cost: freshTracker(), settings: AppSettings(), session: session)
        #expect(saved.map(\.id) == ["gaming-fast"] && saved[0].origin == "trend-refresh")
        #expect(StyleLibrary.profile("gaming-fast")?.idealSeconds == 22)
        #expect(StyleLibrary.history("gaming-fast").count == 2)                  // seed kept as history
        #expect(MockHTTP.seen.allSatisfy { $0.url!.absoluteString.contains("chart=mostPopular") })
        }
    }
}

@Test func zoomDetectionSeesAPunchIn() {
    // A gradient frame, then the same frame zoomed 1.08× around the centre.
    let w = Reframer.thumbW, h = Reframer.thumbH
    let a = (0..<(w * h)).map { i in UInt8((i % w) * 255 / w ^ (i / w) * 7 % 255) }
    let b = (0..<(w * h)).map { i -> UInt8 in
        let x = i % w, y = i / w
        let zx = Int(Double(w) / 2 + (Double(x) - Double(w) / 2) / 1.08), zy = Int(Double(h) / 2 + (Double(y) - Double(h) / 2) / 1.08)
        return a[min(h - 1, zy) * w + min(w - 1, zx)]
    }
    #expect(ReferenceAnalyzer.zoomedIn(a, b))
    #expect(!ReferenceAnalyzer.zoomedIn(a, a))
}

/// Regression: Claude sends "notes" as a list of lines; the plan must still parse.
@Test func planNotesMayBeAListOfLines() throws {
    let json = #"{"mood":"epic","title":"T","beats":[{"purpose":"hook","start":1,"end":2,"caption":"c"}],"notes":["Hook first.","Fast cuts."]}"#
    let sb = try #require(StoryWriter.parse(json))
    #expect(sb.notes == "Hook first.\nFast cuts." && sb.description == "" && sb.hashtags.isEmpty)
    #expect(StoryWriter.parse(#"{"mood":"epic","title":"T","beats":[],"notes":"one string"}"#)?.notes == "one string")
}

/// Punch-ins at scales other than 1.08 must still be detected; a plain shift must not.
@Test func referenceZoomDetectionAcrossScales() {
    let w = Reframer.thumbW, h = Reframer.thumbH
    func img(_ s: Double, dx: Int = 0) -> [UInt8] {
        (0..<(w * h)).map { i in
            let x = Double(w) / 2 + (Double(i % w + dx) - Double(w) / 2) / s, y = Double(h) / 2 + (Double(i / w) - Double(h) / 2) / s
            return UInt8(127 + 120 * sin(x * 0.35) * cos(y * 0.5))
        }
    }
    #expect(ReferenceAnalyzer.zoomedIn(img(1), img(1.15)))
    #expect(ReferenceAnalyzer.zoomedIn(img(1), img(1.2)))
    #expect(!ReferenceAnalyzer.zoomedIn(img(1), img(1, dx: 3)))
}

/// Regression: `zoom+step` never accumulates with d=1 (punch-ins rendered as no-ops); the ramp must use pzoom.
@Test func punchInRampsFromPreviousFrame() {
    let f = EditPlanner.punchIn(1.15, size: (1080, 1920))
    #expect(f.contains("min(pzoom+") && !f.contains("min(zoom+"))
}

/// Model-written profiles are laid over a complete base: partial answers keep the rest, bad enum values are dropped.
@Test func partialProfileMergesOverBase() throws {
    let base = try #require(StyleLibrary.profile("gaming-fast"))
    let patch: [String: Any] = ["pacing": ["avgShotSeconds": 4.2], "captions": ["style": "comic-sans"], "bogus": 1]
    let p = try #require(StyleLibrary.merge(base, patch: patch))
    #expect(p.pacing.avgShotSeconds == 4.2)
    #expect(p.captions.style == base.captions.style && p.id == base.id && p.motion == base.motion)
    #expect(!TrendRefresh.changed(base, { var b = base; b.notes = "x"; b.version = "v2"; return b }()))
    #expect(TrendRefresh.changed(base, p))
}

/// Regression: the Pro Editor look used to replace the caption style chosen in Review, so re-renders never changed it.
@MainActor @Test func reviewCaptionStyleWinsOverTheProEditorLook() throws {
    let (m, _, src) = try makeModel(channel: "UC_me")
    let rec = ClipRecord(Highlight(start: 10, end: 30, title: "t", hook: "", score: 80, reason: "r"), style: .pop)
    rec.source = src; rec.styleID = "gaming-fast"
    let p = try #require(StyleLibrary.profile("gaming-fast"))
    rec.captionStyle = p.captions.style
    #expect(m.clipLook(for: rec)?.captionStyle == p.captions.style && m.clipLook(for: rec)?.uppercase == p.captions.uppercase)
    rec.captionStyle = p.captions.style == .boxed ? .clean : .boxed          // the user picks another style in Review
    let look = try #require(m.clipLook(for: rec))
    #expect(look.captionStyle == rec.captionStyle)
    #expect(look.uppercase == false)                                         // the profile's uppercase belongs to its own style
}
