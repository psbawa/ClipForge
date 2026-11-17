import Foundation
import SwiftData
import Testing
@testable import ClipForgeKit

func moment(_ i: Int, _ s: Double, _ e: Double) -> StoryMoment { StoryMoment(index: i, start: s, end: e, loudness: 50, motion: 50, scene: 50, speech: 0) }
func beat(_ p: String, _ s: Double, _ e: Double, _ c: String = "Caption") -> StoryBeat {
    StoryBeat(purpose: p, start: s, end: e, caption: c, importantAudio: false)
}
func board(_ beats: [StoryBeat]) -> Storyboard { Storyboard(mood: "epic", title: "T", description: "D", hashtags: ["#game"], beats: beats) }

let storyMoments = [moment(1, 10, 22), moment(2, 40, 52), moment(3, 70, 82)]

@Test func storyboardValidation() {
    let good = board([beat("hook", 45, 47.5), beat("buildup", 10, 18), beat("climax", 41, 49), beat("payoff", 72, 80)])
    #expect(StoryWriter.validate(good, moments: storyMoments, duration: 100) == nil)
    #expect(StoryWriter.validate(board([beat("buildup", 10, 18), beat("climax", 41, 49), beat("payoff", 72, 80)]), moments: storyMoments, duration: 100)?.contains("hook") == true)
    #expect(StoryWriter.validate(board([beat("hook", 45, 47), beat("climax", 41, 49), beat("buildup", 10, 18)]), moments: storyMoments, duration: 100)?.contains("payoff") == true)
    #expect(StoryWriter.validate(board([beat("hook", 30, 32), beat("climax", 41, 49), beat("payoff", 72, 80)]), moments: storyMoments, duration: 100)?.contains("candidate") == true)
    #expect(StoryWriter.validate(board([beat("hook", 45, 47), beat("climax", 41, 49), beat("payoff", 80, 79)]), moments: storyMoments, duration: 100)?.contains("invalid times") == true)
    #expect(StoryWriter.parse("Sure! ```json\n{\"mood\":\"epic\",\"title\":\"t\",\"description\":\"d\",\"hashtags\":[],\"beats\":[]}\n```") != nil)
    #expect(StoryWriter.parse("{oops") == nil)
}

@Test func storyboardFitsTargetLengthAndAddsShortsTag() {
    let long = board([beat("hook", 45, 48), beat("buildup", 10, 22), beat("climax", 40, 52), beat("payoff", 70, 82)])  // ~38 s
    let f = StoryWriter.fit(long, target: 30, moments: storyMoments, duration: 100)
    #expect(f.outputDuration <= 30 * 1.05 && f.outputDuration >= 30 * 0.95)
    #expect(f.beats[0].duration == 3)  // the hook is never trimmed
    #expect(f.hashtags.first == "#Shorts")
    let short = board([beat("hook", 45, 46.5), beat("climax", 41, 44), beat("payoff", 72, 75)])  // ~7 s
    #expect(StoryWriter.fit(short, target: 15, moments: storyMoments, duration: 100).outputDuration >= 15 * 0.95)
}

/// Mock Claude that reads the candidate list it was sent and answers with a valid 4-beat storyboard.
final class StoryboardLLM: LLMClient, @unchecked Sendable {
    var calls = 0, images = 0, garbage: Int
    var lastText = ""
    var allText = ""
    init(garbage: Int = 0) { self.garbage = garbage }
    func complete(model: String, system: String, content: [LLMContent], maxTokens: Int, effort: String) async throws -> LLMResponse {
        calls += 1
        images += content.filter { if case .jpeg = $0 { true } else { false } }.count
        lastText = content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
        allText += lastText
        if garbage > 0 { garbage -= 1; return LLMResponse(text: "I think the best moment is…", usage: LLMUsage(input: 10, output: 10)) }
        let re = try! NSRegularExpression(pattern: #"Candidate (\d+): ([\d.]+)–([\d.]+)"#)
        let wins = re.matches(in: lastText, range: NSRange(lastText.startIndex..., in: lastText)).map { m -> (Double, Double) in
            let s = Double(lastText[Range(m.range(at: 2), in: lastText)!])!, e = Double(lastText[Range(m.range(at: 3), in: lastText)!])!
            return (s, e)
        }
        let w = (0..<4).map { wins[min($0, wins.count - 1)] }
        let lens = [2.5, 4.5, 4.5, 4.5], purposes = ["hook", "buildup", "climax", "payoff"], caps = ["ONE HP LEFT", "They had no idea", "THEN THIS HAPPENED", "GG"]
        let beats: [[String: Any]] = (0..<4).map { i in
            let st = w[i].0 + 0.5
            return ["purpose": purposes[i], "start": st, "end": min(st + lens[i], w[i].1), "caption": caps[i], "important_audio": i == 2]
        }
        let obj: [String: Any] = ["mood": "hype", "title": "Clutch at one HP", "description": "Down to one HP.", "hashtags": ["#gaming"], "beats": beats]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        return LLMResponse(text: json, usage: LLMUsage(input: 5000, output: 400))
    }
}

@Test func writerRetriesWithTheProblemThenFails() async throws {
    let llm = StoryboardLLM(garbage: 1)
    var o = StoryOptions(); o.targetSeconds = 15
    let sb = try await StoryWriter.write(client: llm, cost: freshTracker(), settings: AppSettings(), options: o,
                                         moments: storyMoments, words: [], duration: 100)
    #expect(llm.calls == 2 && llm.lastText.contains("rejected"))
    #expect(sb.beats.first?.purpose == "hook" && sb.hashtags.contains("#Shorts"))
    let bad = StoryboardLLM(garbage: 2)
    await #expect(throws: ClipForgeError.self) {
        try await StoryWriter.write(client: bad, cost: freshTracker(), settings: AppSettings(), options: o, moments: storyMoments, words: [], duration: 100)
    }
    #expect(bad.calls == 2)
}

@Test func candidatesFollowTheSignalPeaks() {
    var loud = [Double](repeating: -40, count: 120), motion = [Double](repeating: 2, count: 120)
    for i in 30...33 { loud[i] = -8; motion[i] = 20 }
    for i in 90...92 { loud[i] = -10; motion[i] = 18 }
    let m = StoryAnalyzer.candidates(StorySignals(loudness: loud, motion: motion, scene: motion), words: [], duration: 120, count: 2)
    #expect(m.count == 2)
    #expect(m.contains { $0.start <= 31 && $0.end >= 33 } && m.contains { $0.start <= 91 && $0.end >= 92 })
    #expect(m.map(\.index) == [1, 2])
}

@Test func beatDetectionAndSnapping() {
    let rate = 11025.0
    let clicks: [Float] = (0..<Int(rate * 20)).map { i in
        let t = Double(i) / rate, ph = t.truncatingRemainder(dividingBy: 0.5)   // 120 BPM
        return Float(sin(2 * .pi * 80 * t) * exp(-ph * 30))
    }
    let beats = MusicLibrary.detectBeats(clicks, rate: rate)
    let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }
    #expect(beats.count > 30)
    #expect(abs(gaps.reduce(0, +) / Double(gaps.count) - 0.5) < 0.03)

    let b = [beat("hook", 10, 12.4), beat("payoff", 40, 45)]
    let s = MusicLibrary.snap(b, grid: stride(from: 0.0, to: 20, by: 0.5).map { $0 }, duration: 100)
    let cut = s[0].duration - StoryConfig.crossfade / 2
    #expect(abs(cut - (cut / 0.5).rounded() * 0.5) < 0.001)       // first cut now lands on a beat
    #expect(abs(s[0].end - 12.4) <= StoryConfig.beatSnap)
}

@Test func captionsStayInsideTheSafeZone() {
    for p in [CaptionPlacement.subtitle, .narrative] {
        let r = p.rect(height: 260)
        #expect(r.minY >= 1920 * 0.2)              // clear of the bottom 20%
        #expect(r.maxX <= 1080 * 0.88)             // clear of the right-edge buttons
        #expect(r.minX >= 40 && r.maxY <= 1920 * 0.9)
    }
    #expect(CaptionPlacement.narrative.rect(height: 200).minY > CaptionPlacement.subtitle.rect(height: 200).maxY) // layers don't collide
}

@Test func musicDucksUnderSpeechAndImportantAudio() {
    var sb = board([beat("hook", 10, 13), beat("climax", 40, 45), beat("payoff", 70, 74)])
    sb.beats[1].importantAudio = true
    let words = [Word("no", 11, 11.3), Word("way!", 11.3, 11.8)]
    let spans = StoryRenderer.duckIntervals(sb, words: words)
    #expect(spans.count == 2)
    #expect(abs(spans[0].0 - 0.85) < 0.01)                  // speech at 1 s into the output, padded
    #expect(abs(spans[1].0 - 2.75) < 0.01)                  // climax beat starts at 3 - 0.25
    #expect(StoryRenderer.volumeExpr(spans).hasPrefix("if(gt(between(t,0.85"))
}

actor FixedTranscriber: Transcribing {
    func load(model: String) async throws {}
    func transcribe(_ seg: MediaSegment, progress: (@Sendable (Double) -> Void)?) async throws -> [Word] {
        progress?(1)
        // Continuous commentary so every beat has speech to subtitle and duck under.
        let lines = ["What", "a", "shot!", "No", "way", "he", "survived."]
        return stride(from: 0.2, to: 59.0, by: 0.6).enumerated().map { i, t in Word(lines[i % lines.count], t, t + 0.5) }
    }
}

/// Full job on a synthetic 60 s "gameplay" video: real ffmpeg analysis, music synthesis, beat snapping and render.
@MainActor @Suite(.serialized, .enabled(if: Binaries.detect() != nil)) struct StoryShortsEndToEnd {
    func setup(_ llm: LLMClient) async throws -> (StoryModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipForgeStory-\(UUID())")
        Paths.rootOverride = root.appendingPathComponent("movies")
        StoryConfig.musicRootOverride = root.appendingPathComponent("music")
        let bin = Binaries.detect()!
        let video = root.appendingPathComponent("gameplay.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await Shell.run(bin.ffmpeg, ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=60",
            "-f", "lavfi", "-i", "aevalsrc='0.04*sin(2*PI*220*t)+if(between(t,20,22)+between(t,44,46),0.7*sin(2*PI*440*t),0)':s=48000:d=60",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", video.path])
        let model = StoryModel(container: try Store.container(inMemory: true), binaries: bin, llm: llm,
                               transcriber: FixedTranscriber(), cost: freshTracker()) { AppSettings() }
        return (model, video)
    }

    func wait(_ m: StoryModel, _ j: StoryJob) async {
        for _ in 0..<600 where j.isActive || m.runningJobID != nil { try? await Task.sleep(for: .milliseconds(200)) }
    }

    @Test func rendersAStoryShort() async throws {
        let llm = StoryboardLLM()
        let (model, video) = try await setup(llm)
        var o = StoryOptions(); o.targetSeconds = 15; o.tone = .hype; o.styleID = "gaming-fast"
        let job = try model.create(video: video, options: o)
        await wait(model, job)
        #expect(job.stage == .done, "\(job.errorMessage ?? "")")
        #expect(llm.calls >= 1 && llm.images >= 3)              // frames went to the vision model (+ editor review pass)
        #expect(llm.allText.contains("What a shot!"))            // so did the transcript
        let sb = try #require(job.storyboard)
        #expect(sb.beats.map(\.purpose) == ["hook", "buildup", "climax", "payoff"])
        #expect(job.music?.isPlaceholder == true)               // empty library → generated fallback
        let out = try #require(job.outputURL)
        let bin = Binaries.detect()!
        var info = ""
        do { try await Shell.run(bin.ffmpeg, ["-hide_banner", "-i", out.path]) } catch let e as ClipForgeError { info = e.message }
        #expect(info.contains("1080x1920") && info.contains("h264") && info.contains("Audio: aac"))
        let d = try await IngestService.duration(of: out, ffmpeg: bin.ffmpeg)
        #expect(abs(d - sb.outputDuration) < 0.4)
        let subs = job.folder.appendingPathComponent("captions/subs/captions.ffconcat")
        #expect(FileManager.default.fileExists(atPath: subs.path))   // speech subtitle layer was built
        #expect(!StoryRenderer.duckIntervals(sb, words: try JSONDecoder().decode([Word].self, from: Data(contentsOf: job.folder.appendingPathComponent("words.json")))).isEmpty)
        if let snap = ProcessInfo.processInfo.environment["CLIPFORGE_SNAPSHOT_DIR"] {
            for (i, t) in StoryTimeline.starts(sb.beats).enumerated() {
                try await Shell.run(bin.ffmpeg, ["-loglevel", "error", "-y", "-ss", String(format: "%.2f", t + 0.8), "-i", out.path,
                                                 "-frames:v", "1", "-vf", "scale=360:-2", "\(snap)/beat\(i).png"])
            }
            try? FileManager.default.copyItem(at: out, to: URL(fileURLWithPath: "\(snap)/story.mp4"))
        }
        // Edit a caption and re-render: no new Claude call.
        let callsBefore = llm.calls
        var edited = sb
        edited.beats[0].caption = "Edited hook"
        job.storyboard = edited
        model.rerender(job)
        await wait(model, job)
        #expect(job.stage == .done && llm.calls == callsBefore)
    }

    @Test func badStoryboardFailsWithARealMessage() async throws {
        let (model, video) = try await setup(StoryboardLLM(garbage: 5))
        var o = StoryOptions(); o.styleID = "gaming-fast"
        let job = try model.create(video: video, options: o)
        await wait(model, job)
        #expect(job.stage == .failed)
        #expect(job.failedStage == .writing)
        #expect(job.errorMessage?.contains("invalid edit plan") == true)
        #expect(model.runningJobID == nil)
    }
}
