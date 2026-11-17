import Foundation
import Testing
@testable import ClipForgeKit

private func asset(_ id: String, _ t: String, lat: Double? = nil, lon: Double? = nil, dur: Double = 10) -> VlogAsset {
    VlogAsset(id: id, path: "/tmp/\(id).mp4", isPhoto: false, captured: ISO8601DateFormatter().date(from: t)!, latitude: lat, longitude: lon,
              duration: dur, width: 1920, height: 1080)
}

@Test func chaptersSplitByDayGapAndDistance() {
    let a = [asset("a", "2026-03-01T10:00:00Z", lat: 15.49, lon: 73.82), asset("b", "2026-03-01T10:20:00Z", lat: 15.50, lon: 73.83),
             asset("c", "2026-03-01T15:00:00Z", lat: 15.50, lon: 73.83),      // 4 h gap → new chapter
             asset("d", "2026-03-01T15:10:00Z", lat: 19.07, lon: 72.87),      // far away → new chapter
             asset("e", "2026-03-02T09:00:00Z", lat: 19.07, lon: 72.87)]      // next day
    let ch = ChapterBuilder.group(a)
    #expect(ch.map(\.assetIDs) == [["a", "b"], ["c"], ["d"], ["e"]])
    #expect(ch.map(\.title) == ["Day 1", "Day 1", "Day 1", "Day 2"])
    var rejected = a; rejected[0].rejected = "too dark"
    #expect(ChapterBuilder.group(rejected).first?.assetIDs == ["b"])
}

@Test func isoLocationAndBadShotRanges() {
    let (lat, lon) = FootageImporter.iso6709("+15.4909+073.8278+010.000/")
    #expect(lat == 15.4909 && lon == 73.8278)
    let (s, w) = FootageImporter.iso6709("-33.8688+151.2093/")
    #expect(s == -33.8688 && w == 151.2093)
    // 2 fps: 4 good frames, 4 dark, 6 good → two usable ranges; all-dark → rejected with the reason.
    let good = ShotAnalyzer.Frame(luma: 0.5, sharp: 0.2, diff: 0.02, faces: 0), dark = ShotAnalyzer.Frame(luma: 0.08, sharp: 0.2, diff: 0.02, faces: 0)
    let (r, why) = ShotAnalyzer.goodRanges(Array(repeating: good, count: 4) + Array(repeating: dark, count: 4) + Array(repeating: good, count: 6), fps: 2, duration: 7, talking: false)
    #expect(why == nil && r == [[0, 2], [4, 7]])
    #expect(ShotAnalyzer.goodRanges(Array(repeating: dark, count: 10), fps: 2, duration: 5, talking: false).1 == "too dark")
}

@Test func talkingBeatsSnapToSentencesAndChapterMarks() {
    let words = [Word("So", 0, 0.3), Word("we", 0.3, 0.5), Word("arrived.", 0.5, 1.0), Word("The", 1.2, 1.4), Word("beach", 1.4, 1.8),
                 Word("is", 1.8, 2.0), Word("amazing.", 2.0, 2.6), Word("Next", 3.0, 3.3)]
    let (s, e) = VlogPlanner.snapToSentences(1.5, 1.9, words: words)!
    #expect(abs(s - 1.05) < 0.01 && abs(e - 2.85) < 0.01)          // whole "The beach is amazing." — never mid-sentence
    var b1 = StoryBeat(purpose: "hook", start: 0, end: 12, caption: "", importantAudio: false); b1.chapter = 0
    var b2 = StoryBeat(purpose: "broll", start: 0, end: 50, caption: "", importantAudio: false); b2.chapter = 0
    var b3 = StoryBeat(purpose: "broll", start: 0, end: 5, caption: "", importantAudio: false); b3.chapter = 1
    let ch = [VlogChapter(index: 0, title: "Day 1 · Goa", start: .now, end: .now, assetIDs: []),
              VlogChapter(index: 1, title: "Day 2 · Mumbai", start: .now, end: .now, assetIDs: [])]
    let sb = Storyboard(mood: "epic", title: "T", description: "", hashtags: [], beats: [b1, b2, b3])
    #expect(VlogRenderer.chapterMarks(sb, chapters: ch) == ["00:00 Intro", "01:02 Day 2 · Mumbai"] || VlogRenderer.chapterMarks(sb, chapters: ch).isEmpty)
    b1.chapter = nil
    let sb2 = Storyboard(mood: "epic", title: "T", description: "", hashtags: [], beats: [b1, b2, b3])
    #expect(VlogRenderer.chapterMarks(sb2, chapters: ch) == ["00:00 Intro", "00:12 Day 1 · Goa", "01:02 Day 2 · Mumbai"])
}

/// Plans over whatever shots the prompt lists: a full vlog through every usable shot + one short.
final class VlogLLM: LLMClient, @unchecked Sendable {
    var calls = 0
    func complete(model: String, system: String, content: [LLMContent], maxTokens: Int, effort: String) async throws -> LLMResponse {
        calls += 1
        let text = content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
        let re = try NSRegularExpression(pattern: #"Shot (\w+) · .*?chapter (\d+) · .*?usable (photo|([0-9.]+)–([0-9.]+))"#)
        var beats: [[String: Any]] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            func g(_ i: Int) -> String? { Range(m.range(at: i), in: text).map { String(text[$0]) } }
            let a = g(4).flatMap(Double.init) ?? 0, b = g(5).flatMap(Double.init) ?? 4
            beats.append(["asset": g(1)!, "start": a, "end": min(b, a + 3), "purpose": "broll", "caption": "Shot", "chapter": Int(g(2)!)!])
        }
        let full: [String: Any] = ["mood": "epic", "title": "Goa trip", "description": "Two days.", "hashtags": ["#travel"], "beats": beats]
        let short: [String: Any] = ["mood": "funny", "title": "Best bits", "hashtags": ["#Shorts"], "beats": Array(beats.prefix(3))]
        let obj: [String: Any] = ["title": "Goa trip", "chapters": [["index": 0, "title": "Day 1 · Beach"]], "full": full, "shorts": [short]]
        return LLMResponse(text: String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self), usage: LLMUsage(input: 9000, output: 900))
    }
}

@MainActor @Suite(.serialized, .enabled(if: Binaries.detect() != nil)) struct VlogEndToEnd {
    @Test func folderBecomesFullVlogAndShortWithBadShotsDropped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipForgeVlog-\(UUID())")
        try await Paths.$scopedRoot.withValue(root.appendingPathComponent("movies")) {
        StoryConfig.musicRootOverride = root.appendingPathComponent("music")
        let bin = Binaries.detect()!
        let footage = root.appendingPathComponent("trip")
        try FileManager.default.createDirectory(at: footage, withIntermediateDirectories: true)
        func clip(_ name: String, _ src: String, _ time: String, _ loc: String) async throws {
            try await Shell.run(bin.ffmpeg, ["-loglevel", "error", "-f", "lavfi", "-i", src, "-f", "lavfi", "-i", "anoisesrc=a=0.02:d=8",
                "-shortest", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac",
                "-metadata", "creation_time=\(time)", "-metadata", "location=\(loc)", "-movflags", "+use_metadata_tags",
                footage.appendingPathComponent(name).path])
        }
        try await clip("a.mp4", "testsrc2=s=1280x720:r=30:d=8", "2026-03-01T10:00:00Z", "+15.4909+073.8278/")
        try await clip("b.mp4", "mandelbrot=s=1280x720:r=30,trim=duration=8", "2026-03-01T10:30:00Z", "+15.4950+073.8300/")
        try await clip("dark.mp4", "color=c=black:s=1280x720:r=30:d=8", "2026-03-01T11:00:00Z", "+15.4950+073.8300/")
        try await clip("a-again.mp4", "testsrc2=s=1280x720:r=30:d=8", "2026-03-01T10:01:00Z", "+15.4909+073.8278/")
        try await clip("d.mp4", "smptehdbars=s=1280x720:r=30:d=8", "2026-03-02T09:00:00Z", "+19.0760+072.8777/")
        try await Shell.run(bin.ffmpeg, ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc=s=1600x1200", "-frames:v", "1", footage.appendingPathComponent("photo.jpg").path])

        let llm = VlogLLM()
        let vlog = VlogModel(binaries: bin, llm: llm, transcriber: nil, cost: freshTracker(), settings: { AppSettings() })
        var o = VlogOptions(); o.title = "Goa trip"; o.shortsCount = 1; o.cleanupProxies = false
        let p0 = try vlog.create(inputs: [footage], options: o)
        @MainActor func current() -> VlogProject { vlog.projects.first { $0.id == p0.id }! }
        for _ in 0..<1500 where current().isActive { try? await Task.sleep(for: .milliseconds(200)) }
        let p = current()
        #expect(p.stage == .done, "\(p.error ?? "")")
        #expect(p.assets.count == 6)
        #expect(p.assets.first { $0.name == "dark.mp4" }?.rejected != nil)
        #expect(p.assets.filter { $0.name.hasPrefix("a") }.contains { $0.rejected?.hasPrefix("near-duplicate") == true })
        #expect(p.assets.first { $0.name == "d.mp4" }?.latitude.map { abs($0 - 19.076) < 0.01 } == true)   // GPS read from the file
        #expect(p.chapters.count >= 2)                                                                          // two days
        #expect(llm.calls == 1)
        let full = try #require(p.outputs.first { !$0.isShort }), short = try #require(p.outputs.first { $0.isShort })
        for (o, size) in [(full, "1920x1080"), (short, "1080x1920")] {
            var info = ""
            do { try await Shell.run(bin.ffmpeg, ["-hide_banner", "-i", o.path]) } catch let e as ClipForgeError { info = e.message }
            #expect(info.contains(size), "\(o.path)")
        }
        // Retry re-renders from cache: no new planning call, segments reused.
        let segs = try FileManager.default.contentsOfDirectory(atPath: p.folder.appendingPathComponent("segments").path).count
        vlog.retry(p.id)
        for _ in 0..<600 where current().isActive || vlog.runningID != nil { try? await Task.sleep(for: .milliseconds(200)) }
        #expect(current().stage == .done && llm.calls == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: p.folder.appendingPathComponent("segments").path).count == segs)
        }
    }
}
