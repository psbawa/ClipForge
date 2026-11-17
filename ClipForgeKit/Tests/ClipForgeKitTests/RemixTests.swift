import Foundation
import SwiftData
import Testing
@testable import ClipForgeKit

@Test func timelineHandlesCutsCrossfadesAndSlowMotion() {
    let b = [StoryBeat(purpose: "hook", start: 10, end: 12, caption: "h", importantAudio: false),
             StoryBeat(purpose: "moment", start: 50, end: 53, caption: "m", importantAudio: false, transition: "cut"),
             StoryBeat(purpose: "climax", start: 90, end: 92, caption: "c", importantAudio: false, transition: "flash", speed: 0.5)]
    let s = StoryTimeline.starts(b)
    #expect(abs(s[1] - (2 - 0.04)) < 1e-9)                         // hard cut ≈ no overlap
    #expect(abs(s[2] - (s[1] + 3 - StoryConfig.crossfade)) < 1e-9)  // flash overlaps by the crossfade
    #expect(abs(StoryTimeline.duration(b) - (s[2] + 4)) < 1e-9)     // slow-mo doubles the last beat
    #expect(StoryTimeline.transition(b[2]).name == "fadewhite" && StoryTimeline.transition(b[1]).duration < 0.05)
    let w = StoryTimeline.words([Word("boom", 91, 91.5)], beats: b)
    #expect(abs(w[0].start - (s[2] + 2)) < 1e-9 && abs(w[0].end - (s[2] + 3)) < 1e-9)   // caption timing follows slow-mo
}

@Test func remixPlansAreValidatedPerStyle() {
    let m = [moment(1, 0, 60), moment(2, 100, 160), moment(3, 200, 260)]
    func plan(_ beats: [(String, Double, Double)]) -> Storyboard {
        board(beats.map { beat($0.0, $0.1, $0.2) })
    }
    let good = plan([("hook", 210, 212), ("moment", 10, 13), ("moment", 120, 123), ("climax", 205, 208), ("payoff", 230, 233)])
    #expect(StoryWriter.validate(good, moments: m, duration: 300, style: .montage) == nil)
    let overlap = plan([("hook", 210, 212), ("moment", 10, 13), ("moment", 11, 14), ("payoff", 230, 233)])
    #expect(StoryWriter.validate(overlap, moments: m, duration: 300, style: .montage)?.contains("overlap") == true)
    let tooLong = plan([("hook", 210, 212), ("moment", 10, 20), ("moment", 120, 123), ("payoff", 230, 233)])
    #expect(StoryWriter.validate(tooLong, moments: m, duration: 300, style: .montage)?.contains("longer") == true)
    let unordered = plan([("hook", 230, 232), ("moment", 120, 123), ("moment", 10, 13), ("payoff", 210, 213)])
    #expect(StoryWriter.validate(unordered, moments: m, duration: 300, style: .recap)?.contains("chronological") == true)
    #expect(StoryWriter.validate(unordered, moments: m, duration: 300, style: .funny) == nil)
}

@Test func candidatesCoverTheWholeTimeline() {
    // All the action is in the first 3 minutes of a 20-minute video.
    let n = 1200
    var loud = [Double](repeating: -40, count: n), motion = [Double](repeating: 2, count: n)
    for i in 0..<180 where i % 20 < 5 { loud[i] = -8; motion[i] = 20 }
    for i in stride(from: 300, to: n, by: 97) { loud[i] = -25; motion[i] = 6 }
    let sig = StorySignals(loudness: loud, motion: motion, scene: motion)
    let plain = StoryAnalyzer.candidates(sig, words: [], duration: Double(n), count: 10, window: 8)
    let spread = StoryAnalyzer.candidates(sig, words: [], duration: Double(n), count: 10, window: 8, buckets: 10)
    #expect(plain.filter { $0.start > 600 }.count < spread.filter { $0.start > 600 }.count)
    #expect(Set(spread.map { Int($0.start) / 120 }).count >= 8)        // ≥ 8 of the 10 timeline slices represented
}

/// Mock Claude that builds a chronological montage from whatever candidates it's sent.
final class RemixLLM: LLMClient, @unchecked Sendable {
    var calls = 0, lastSystem = "", systems: [String] = []
    func complete(model: String, system: String, content: [LLMContent], maxTokens: Int, effort: String) async throws -> LLMResponse {
        calls += 1; lastSystem = system; systems.append(system)
        let text = content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
        let re = try! NSRegularExpression(pattern: #"Candidate (\d+): ([\d.]+)–([\d.]+)"#)
        let wins = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m -> (Double, Double) in
            (Double(text[Range(m.range(at: 2), in: text)!])!, Double(text[Range(m.range(at: 3), in: text)!])!)
        }
        var beats: [[String: Any]] = [["purpose": "hook", "start": wins.last!.0 + 0.5, "end": wins.last!.0 + 2.0, "caption": "WAIT FOR IT", "transition": "cut"]]
        let step = max(1, wins.count / 6)
        for (k, w) in stride(from: 0, to: wins.count, by: step).prefix(6).map({ wins[$0] }).enumerated() {
            beats.append(["purpose": k == 5 ? "payoff" : "moment", "start": w.0 + 3, "end": w.0 + 5.5, "caption": "Moment \(k + 1)",
                          "transition": k == 2 ? "flash" : "cut", "speed": k == 4 ? 0.5 : 1])
        }
        let obj: [String: Any] = ["mood": "hype", "title": "Best moments", "description": "d", "hashtags": ["#gaming"], "beats": beats]
        return LLMResponse(text: String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self), usage: LLMUsage(input: 4000, output: 400))
    }
}

@MainActor @Suite(.serialized, .enabled(if: Binaries.detect() != nil)) struct RemixEndToEnd {
    @Test func landscapeMontageLandsInReviewAndTimelineEditsReRender() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipForgeRemix-\(UUID())")
        try await Paths.$scopedRoot.withValue(root.appendingPathComponent("movies")) {
        StoryConfig.musicRootOverride = root.appendingPathComponent("music")
        let bin = Binaries.detect()!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("long.mp4")
        try await Shell.run(bin.ffmpeg, ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=240",
            "-f", "lavfi", "-i", "aevalsrc='0.05*sin(2*PI*220*t)+if(lt(mod(t,40),2),0.7*sin(2*PI*440*t),0)':s=48000:d=240",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", video.path])
        let llm = RemixLLM()
        let app = AppModel(container: try Store.container(inMemory: true), binaries: bin, llm: llm, cost: freshTracker(),
                           ingest: MockIngest(dur: 240), transcriber: FixedTranscriber(), clipper: MockClipper(), publisher: MockPublisher(channelID: "UC_me"))
        let story = app.makeStoryModel()
        var o = StoryOptions(); o.style = .montage; o.format = .landscape; o.targetSeconds = 15; o.prompt = "only the loud parts"; o.styleID = "gaming-fast"
        let job = try story.create(video: video, options: o)
        for _ in 0..<900 where job.isActive || story.runningJobID != nil { try? await Task.sleep(for: .milliseconds(200)) }
        #expect(job.stage == .done, "\(job.errorMessage ?? "")")
        #expect(llm.systems.contains { $0.contains("Montage") && $0.contains("WHOLE video") && $0.contains("EDITING STYLE") })
        #expect(llm.systems.contains { $0.contains("senior short-form video editor") })     // self-review pass ran
        let sb = try #require(job.storyboard)
        #expect(Set(job.moments.map { Int($0.start) / 60 }).count == 4)                 // candidates cover all 4 minutes
        #expect(Set(sb.beats.dropFirst().map { Int($0.start) / 60 }).count >= 3)       // and so does the edit
        var info = ""
        do { try await Shell.run(bin.ffmpeg, ["-hide_banner", "-i", job.outputPath!]) } catch let e as ClipForgeError { info = e.message }
        #expect(info.contains("1920x1080"))
        let d = try await IngestService.duration(of: URL(fileURLWithPath: job.outputPath!), ffmpeg: bin.ffmpeg)
        #expect(abs(d - sb.outputDuration) < 0.4)
        // Lands in the review flow as a clip linked to the edit plan.
        let clip = try #require(try app.context.fetch(FetchDescriptor<ClipRecord>()).first { $0.storyJobID == job.id })
        #expect(clip.status == .ready && clip.videoPath == job.outputPath && clip.source?.url.hasPrefix("file://") == true)
        #expect(RightsGuard.canPublish(clip.source!, to: Channel(id: "UC_me", title: "Me")) == nil)
        // Timeline edit: drop a segment, swap order, re-render without a new Claude call.
        let callsBefore = llm.calls
        var edited = sb
        edited.beats.remove(at: 2)
        edited.beats.swapAt(1, 2)
        job.storyboard = edited
        story.rerender(job)
        for _ in 0..<900 where job.isActive || story.runningJobID != nil { try? await Task.sleep(for: .milliseconds(200)) }
        #expect(job.stage == .done && llm.calls == callsBefore)
        #expect(job.storyboard!.beats.count == sb.beats.count - 1)
        #expect(try app.context.fetch(FetchDescriptor<ClipRecord>()).filter { $0.storyJobID == job.id }.count == 1)  // same clip updated
        }
    }
}
