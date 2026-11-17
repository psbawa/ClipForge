import Foundation
import SwiftData
import Testing
@testable import ClipForgeKit

typealias RBox = Reframer.Box
func face(_ x: Double, _ y: Double = 0.2, w: Double = 0.1, mouth: Double = 0) -> Reframer.Face {
    .init(box: RBox(x: x - w / 2, y: y, w: w, h: w * 1.6), mouth: mouth)
}
func samples(_ n: Int, from t0: Double = 0, _ make: (Int) -> Reframer.Sample) -> [Reframer.Sample] {
    (0..<n).map { var s = make($0); s.t = t0 + Double($0) / Reframer.sampleFPS; return s }
}

@Test func trackingFollowsTheSubjectSmoothlyAndJumpsOnlyAtCuts() {
    // Shot 1 (0–5 s): a face walks from x=0.3 to x=0.7. Shot 2 (5–8 s): a face at x=0.15.
    let s1 = samples(20) { i in .init(t: 0, faces: [face(0.3 + 0.4 * Double(i) / 19)]) }
    let s2 = samples(12, from: 5) { _ in .init(t: 0, faces: [face(0.15)]) }
    let plan = Reframer.build(samples: s1 + s2, cuts: [5.0], duration: 8, aspect: 16 / 9, words: [], framing: .smart)
    #expect(plan.shots.count == 2 && plan.shots.allSatisfy { $0.mode == .track })
    let a = plan.shots[0].keys, b = plan.shots[1].keys
    let maxStep = zip(a.dropFirst(), a).map { abs($0 - $1) }.max()!
    #expect(maxStep <= Reframer.panSpeed / Reframer.sampleFPS + 0.001)       // no jumps inside a shot
    #expect(a.last! > a.first! + 0.15)                                         // it followed the subject
    let cw = plan.cropWidth
    #expect(abs(a.last! - 0.7) <= cw / 2)                                      // subject ends inside the crop
    #expect(abs(b[0] - max(cw / 2, 0.15)) < 0.02)                              // new shot starts on its subject
}

@Test func twoSpeakersPicksTheActiveOneOrFallsBackToBlurFill() {
    let words = (0..<16).map { Word("w", Double($0) * 0.25, Double($0) * 0.25 + 0.2) }
    // Faces far apart (don't fit one 9:16 crop). Right face's mouth moves while someone speaks.
    let talking = samples(16) { i in .init(t: 0, faces: [face(0.15), face(0.85, mouth: i % 2 == 0 ? 0.05 : 0.3)]) }
    let p = Reframer.build(samples: talking, cuts: [], duration: 4, aspect: 16 / 9, words: words, framing: .smart)
    #expect(p.shots[0].mode == .track && p.shots[0].reason == "active speaker")
    #expect(p.shots[0].keys.allSatisfy { $0 > 0.6 })
    // Same framing, nobody clearly talking → don't crop anyone out.
    let silent = samples(16) { _ in .init(t: 0, faces: [face(0.15), face(0.85)]) }
    #expect(Reframer.build(samples: silent, cuts: [], duration: 4, aspect: 16 / 9, words: [], framing: .smart).shots[0].mode == .fill)
    // Two people close together fit → frame both.
    let close = samples(8) { _ in .init(t: 0, faces: [face(0.45), face(0.55)]) }
    let c = Reframer.build(samples: close, cuts: [], duration: 2, aspect: 16 / 9, words: [], framing: .smart).shots[0]
    #expect(c.mode == .track && abs(c.keys[0] - 0.5) < 0.03)
    // Vertical source is never cropped.
    #expect(Reframer.build(samples: close, cuts: [], duration: 2, aspect: 9 / 16, words: [], framing: .smart).shots[0].mode == .fill)
}

@Test func lowFacesGetHeadroomAboveTheCaptionZone() {
    let low = samples(8) { _ in .init(t: 0, faces: [face(0.5, 0.62, w: 0.12)]) }   // face bottom ≈ 0.81
    let s = Reframer.build(samples: low, cuts: [], duration: 2, aspect: 16 / 9, words: [], framing: .smart).shots[0]
    #expect(s.zoom > 1 && s.zoom <= Reframer.maxZoom && s.top > 0)
    let bottomInCrop = (0.62 + 0.192 - s.top) * s.zoom
    let topInCrop = (0.62 - s.top) * s.zoom
    #expect(bottomInCrop < Reframer.captionZone + 0.02 && topInCrop > 0)
    // Gameplay with no people: follow the motion.
    let game = samples(8) { _ in .init(t: 0, motion: RBox(x: 0.7, y: 0.4, w: 0.1, h: 0.1)) }
    let g = Reframer.build(samples: game, cuts: [], duration: 2, aspect: 16 / 9, words: [], framing: .smart).shots[0]
    #expect(g.reason == "centre of action" && abs(g.keys.last! - 0.75) <= 0.2)
}

/// Regression (letterboxing bug): gameplay with wide, diffuse motion and saliency and no people must be cropped, not blur-filled.
@Test func gameplayWithWideMotionIsCroppedNotFilled() {
    let game = samples(20) { i in
        .init(t: 0, motion: RBox(x: 0.6 + 0.01 * Double(i), y: 0.4, w: 0.08, h: 0.08), salient: RBox(x: 0.1, y: 0.1, w: 0.8, h: 0.7))
    }
    let s = Reframer.build(samples: game, cuts: [], duration: 5, aspect: 16 / 9, words: [], framing: .smart).shots[0]
    #expect(s.mode == .track && s.reason == "centre of action")
    #expect(s.keys.allSatisfy { $0 > 0.5 })                      // pulled toward the action on the right
    // HUD element at the edge barely moves the crop.
    let hud = samples(8) { _ in .init(t: 0, salient: RBox(x: 0.92, y: 0.05, w: 0.06, h: 0.05)) }
    let h = Reframer.build(samples: hud, cuts: [], duration: 2, aspect: 16 / 9, words: [], framing: .smart).shots[0]
    #expect(h.mode == .track && abs(h.keys[0] - 0.5) < 0.2)
    // A single large person never triggers the fill.
    let close = samples(8) { _ in .init(t: 0, people: [RBox(x: 0.1, y: 0.1, w: 0.8, h: 0.9)]) }
    #expect(Reframer.build(samples: close, cuts: [], duration: 2, aspect: 16 / 9, words: [], framing: .smart).shots[0].mode == .track)
    // Two people far apart, nobody clearly talking → the one justified fill, with its reason.
    let apart = samples(8) { _ in .init(t: 0, people: [RBox(x: 0.02, y: 0.1, w: 0.2, h: 0.8), RBox(x: 0.78, y: 0.1, w: 0.2, h: 0.8)]) }
    let f = Reframer.build(samples: apart, cuts: [], duration: 2, aspect: 16 / 9, words: [], framing: .smart)
    #expect(f.shots[0].mode == .fill && f.shots[0].reason.contains("too far apart") && f.summary.contains("blur fill"))
}

@Test func manualFramingAndOverrideParsing() {
    let m = Reframer.build(samples: samples(4) { _ in .init(t: 0) }, cuts: [], duration: 1, aspect: 16 / 9, words: [], framing: .manual(0.9)).shots[0]
    #expect(m.mode == .track && m.reason == "manual position" && abs(m.keys[0] - (1 - 0.316 / 2)) < 0.01)  // clamped inside the frame
    #expect(Framing(raw: Framing.manual(0.25).raw) == .manual(0.25) && Framing(raw: "blur") == .blur && Framing(raw: nil) == .smart)
}

@Test func signalWindowsRankTheBurstAndKeepPeaksInside() {
    let sig = testSignals(420)
    let w = MomentFinder.windows(sig, words: [], transcriptRatings: [], duration: 420)
    #expect(w.count == Int((420 - SelectionConfig.windowSeconds) / SelectionConfig.stepSeconds) + 1)
    let best = MomentFinder.top(w, count: 3)
    let first = best.max { $0.preScore < $1.preScore }!
    #expect((203...215).contains(first.peak) && first.start <= first.peak && first.end >= first.peak)   // the burst wins
    #expect(first.signals["speech"] == 0 && first.signals["transcript"] == 0)     // constant signals carry no weight
    for (a, b) in zip(best, best.dropFirst()) { #expect(a.end - b.start <= 0.3 * SelectionConfig.windowSeconds) } // no big overlaps
    var rated = best
    for i in rated.indices { rated[i].vision = rated[i].index == first.index ? 90 : 30; rated[i].reason = "r" }
    let picks = MomentFinder.pick(rated, words: [], cuts: MomentFinder.cuts(sig), duration: 420, settings: { var s = AppSettings(); s.minClipsPerVideo = 1; return s }())
    #expect(picks.count == 1)
    let p = picks[0]
    #expect(p.start <= first.peak - SelectionConfig.leadIn && p.end >= first.peak + SelectionConfig.payoff && p.duration >= 20)
    #expect(p.signals["final"] == Int(rated.first { $0.index == first.index }!.final.rounded()))
}

@Test func filterGraphSplitsShots() {
    let plan = Reframer.build(samples: samples(12) { _ in .init(t: 0, faces: [face(0.5)]) }, cuts: [1.5], duration: 3, aspect: 16 / 9, words: [], framing: .smart)
    let g = Reframer.filter(plan, input: "0:v", output: "v", tag: "r")
    #expect(g.contains("split=2") && g.contains("concat=n=2") && g.contains("trim=start=1.500"))
    #expect(Reframer.filter(Reframer.build(samples: [], cuts: [], duration: 2, aspect: 16 / 9, words: [], framing: .blur), input: "0:v", output: "v", tag: "r").contains("gblur"))
}

/// Real render: a hard cut at 5 s sits inside the pre-roll → the clip starts exactly on the cut.
@Test(.enabled(if: Binaries.detect() != nil))
func renderSnapsClipStartToSceneCut() async throws {
    let bin = try #require(Binaries.detect())
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let v = dir.appendingPathComponent("src.mp4")
    try await Shell.run(bin.ffmpeg, ["-loglevel", "error", "-f", "lavfi", "-i", "color=c=red:s=1280x720:r=30:d=5", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=10",
                                     "-f", "lavfi", "-i", "sine=f=300:d=15", "-filter_complex", "[0:v][1:v]concat=n=2:v=1[v]", "-map", "[v]", "-map", "2:a",
                                     "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", v.path])
    let seg = MediaSegment(url: v, start: 0, end: 15)
    let r = try await ClipService(ffmpeg: bin.ffmpeg).render(start: 4.4, end: 12, keep: 5.5...11, from: [seg], words: [], style: .pop, framing: .smart, voice: nil, look: nil, to: dir.appendingPathComponent("out"))
    #expect(abs(r.start - 5.0) < 0.15, "start \(r.start)")
    #expect(r.end == 12)
    let framing = try JSONDecoder().decode(Reframer.Plan.self, from: Data(contentsOf: r.video.deletingPathExtension().appendingPathExtension("framing.json")))
    #expect(!framing.rawCuts.contains { $0 > 0.2 && $0 < 1 })   // the red flash is gone from the clip
}

@MainActor @Suite(.serialized) struct ReviewFlowTests {
    func setup(channel: String = "UC_me") throws -> (AppModel, MockPublisher, ClipRecord, MockClipper) {
        useTempRoot()
        let pub = MockPublisher(channelID: channel), clipper = MockClipper()
        let model = AppModel(container: try Store.container(inMemory: true), binaries: nil, llm: MockLLM([]), cost: freshTracker(),
                             ingest: MockIngest(dur: 420), transcriber: MockTranscriber(), clipper: clipper, publisher: pub)
        let src = Source(url: "https://youtube.com/watch?v=x", info: SourceInfo(title: "Stream", channelID: "UC_me", channelName: "Me", isLive: false, duration: 420))
        src.ownershipConfirmedAt = .now
        model.context.insert(src)
        var h = Highlight(start: 200, end: 225, title: "Cat opens fridge", hook: "h", score: 88, reason: "peak")
        h.description = "The cat did it.\n\n#cats #funny #Shorts"
        let rec = ClipRecord(h, style: .pop)
        rec.source = src
        model.context.insert(rec)
        return (model, pub, rec, clipper)
    }

    @Test func needsReviewToEditedToApprovedToDownloadedAndPublished() async throws {
        let (model, pub, rec, clipper) = try setup()
        #expect(rec.hashtags == ["#cats", "#funny", "#Shorts"] && rec.descriptionText == "The cat did it.")
        await model.render(rec, words: sampleTranscript)
        #expect(rec.status == .ready)                                    // Needs review
        // Edit: trim + caption text → re-render uses the edited words.
        rec.captionWords = [Word("EDITED", 201, 202), Word("caption", 202, 203)]
        await model.rerender(rec, start: 199, end: 226, style: .boxed)
        #expect(rec.status == .ready && rec.start == 199 && rec.captionStyle == .boxed)
        let used = await clipper.lastWords
        #expect(used.contains { $0.text == "EDITED" } && !used.contains { $0.start >= 201 && $0.end <= 203 && $0.text != "EDITED" && $0.text != "caption" })
        // Approve → Download (mp4 + srt + txt with hashtags).
        rec.title = "Edited title"
        model.approve(rec)
        #expect(rec.status == .approved)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = try #require(model.download(rec, to: dir))
        let txt = try String(contentsOf: out.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        #expect(txt.hasPrefix("Edited title") && txt.contains("#cats #funny #Shorts"))
        #expect(FileManager.default.fileExists(atPath: out.deletingPathExtension().appendingPathExtension("srt").path))
        #expect(rec.status == .downloaded)
        // Then publish it too.
        await model.approveAndPublish(rec)
        #expect(rec.status == .published && rec.videoID == "v1")
        let uploads = await pub.uploads
        #expect(uploads == ["Edited title"])   // metadata() appends #Shorts at upload time (covered in PublishTests)
    }

    @Test func failedPublishShowsErrorAndRetries() async throws {
        let (model, _, rec, _) = try setup(channel: "UC_other")       // foreign channel, no permission recorded
        await model.render(rec, words: sampleTranscript)
        await model.approveAndPublish(rec)
        #expect(rec.status == .approved && rec.lastError?.contains("Not published") == true)   // blocked with a visible reason
        // A publish failure → Failed with the error → Retry publishes.
        rec.status = .failed; rec.failure = .publish; rec.lastError = "quota"
        rec.source?.permissionConfirmedAt = .now
        await model.retry(rec)
        #expect(rec.status == .published && rec.failure == nil)
    }

    @Test func bulkApproveAndRejectPersist() async throws {
        let (model, _, rec, _) = try setup()
        let other = ClipRecord(Highlight(start: 300, end: 330, title: "B", hook: "", score: 70, reason: ""), style: .pop)
        other.source = rec.source
        model.context.insert(other)
        await model.render(rec, words: sampleTranscript)
        await model.render(other, words: sampleTranscript)
        model.approveAll([rec, other])
        #expect(rec.status == .approved && other.status == .approved)
        let otherID = other.id
        model.rejectAll([other], reason: "dupe")
        let fetched = try model.context.fetch(FetchDescriptor<ClipRecord>())
        #expect(!fetched.contains { $0.id == otherID } && fetched.contains { $0.id == rec.id && $0.statusRaw == "approved" })
    }

    @Test func rejectDeletesTheClipAndItsFilesAndNeverCutsItAgain() async throws {
        let (model, _, rec, _) = try setup()
        await model.render(rec, words: sampleTranscript)
        let video = try #require(rec.videoURL), srt = URL(fileURLWithPath: try #require(rec.srtPath))
        #expect(FileManager.default.fileExists(atPath: video.path) && FileManager.default.fileExists(atPath: srt.path))
        let src = try #require(rec.source), (id, start, end) = (rec.id, rec.start, rec.end)
        model.reject(rec, reason: "boring")
        #expect(try model.context.fetch(FetchDescriptor<ClipRecord>()).allSatisfy { $0.id != id })
        #expect(!FileManager.default.fileExists(atPath: video.path) && !FileManager.default.fileExists(atPath: srt.path))
        #expect(src.rejectedRanges == [[start, end]])
        // The same moment found again (re-run / overlapping live window) is skipped.
        #expect(model.isDuplicate(Highlight(start: start + 1, end: end - 1, title: "", hook: "", score: 90, reason: ""), in: src))
        #expect(!model.isDuplicate(Highlight(start: 380, end: 410, title: "", hook: "", score: 90, reason: ""), in: src))
    }

    @Test func clipsRejectedBeforeThisChangeArePurgedAtLaunch() async throws {
        let (model, _, rec, _) = try setup()
        await model.render(rec, words: sampleTranscript)
        rec.status = .rejected
        let video = try #require(rec.videoURL)
        await model.reconcileInterruptedUploads()
        #expect(try model.context.fetch(FetchDescriptor<ClipRecord>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: video.path))
    }
}
