import Foundation
import SwiftData
import Testing
@testable import ClipForgeKit

actor MockIngest: Ingesting {
    let dur: Double
    init(dur: Double) { self.dur = dur }
    func probe(_ url: String) async throws -> SourceInfo { SourceInfo(title: "Stream", channelID: "UC_me", channelName: "Me", isLive: false, duration: dur) }
    func downloadVOD(_ url: String, into dir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaSegment {
        MediaSegment(url: dir.appendingPathComponent("source.mp4"), start: 0, end: dur)
    }
    func startLive(_ url: String, into dir: URL, bufferMinutes: Double) -> AsyncStream<MediaSegment> { AsyncStream { $0.finish() } }
    func stopLive() {}
    func segments(from: Double, to: Double) -> [MediaSegment] { [MediaSegment(url: URL(fileURLWithPath: "/dev/null"), start: 0, end: dur)] }
}

actor MockTranscriber: Transcribing {
    func load(model: String) async throws {}
    func transcribe(_ seg: MediaSegment, progress: (@Sendable (Double) -> Void)?) async throws -> [Word] { sampleTranscript }
}

actor MockClipper: ClipRendering {
    var lastWords: [Word] = []
    var lastFraming: Framing?
    var lastVoice: VoiceMix?
    var lastKeep: ClosedRange<Double>?
    var lastLook: ClipLook?
    func render(start: Double, end: Double, keep: ClosedRange<Double>, from segments: [MediaSegment], words: [Word],
                style: CaptionStyle, framing: Framing, voice: VoiceMix?, look: ClipLook?, to dir: URL) async throws -> RenderedClip {
        lastFraming = framing; lastVoice = voice; lastKeep = keep; lastLook = look
        lastWords = words
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let v = dir.appendingPathComponent("c\(Int(start)).mp4"), srt = dir.appendingPathComponent("c\(Int(start)).srt")
        try Data(repeating: 1, count: 100).write(to: v)
        try Data("1\n".utf8).write(to: srt)
        return RenderedClip(video: v, srt: srt, start: start, end: end)
    }
    func debugPreview(start: Double, end: Double, from segments: [MediaSegment], words: [Word], framing: Framing, to dir: URL) async throws -> URL {
        throw ClipForgeError("not in tests")
    }
}

actor MockPublisher: Publishing {
    var uploads: [String] = []
    var channelID: String
    init(channelID: String) { self.channelID = channelID }
    func channel() async throws -> Channel { Channel(id: channelID, title: "Mine") }
    func startSession(_ r: UploadRequest) async throws -> URL { URL(string: "https://up/\(uploads.count)")! }
    func upload(_ r: UploadRequest, session: URL) async throws -> UploadResult {
        uploads.append(r.title)
        return UploadResult(videoID: "v\(uploads.count)", privacy: r.privacy, channelID: channelID)
    }
    func status(session: URL, size: Int64) async throws -> SessionState { .partial(0) }
}

let stageA = #"[{"start": 200, "end": 225, "title": "Craziest play", "hook": "No way", "score": 90, "reason": "peak"}]"#
let stageB = #"[{"index": 0, "score": 92, "title": "The craziest play", "description": "Wow", "tags": ["x"]}]"#

func useTempRoot() {
    if Paths.rootOverride == nil { Paths.rootOverride = FileManager.default.temporaryDirectory.appendingPathComponent("ClipForgeTests-\(UUID())") }
}

/// Mock Claude for the selection flow: Haiku gets scripted transcript ratings; Sonnet rates every candidate it is
/// sent ("Candidate N: a–b s") with `rate(start, end)`, or answers garbage.
final class RatingLLM: LLMClient, @unchecked Sendable {
    var haiku: [String]
    var rate: (Double, Double) -> Int
    var garbage = false
    var sonnetCalls = 0, images = 0
    let lock = NSLock()
    init(haiku: [String] = [stageA], rate: @escaping (Double, Double) -> Int = { s, e in s <= 205 && e >= 210 ? 95 : 25 }) { self.haiku = haiku; self.rate = rate }
    func complete(model: String, system: String, content: [LLMContent], maxTokens: Int, effort: String) async throws -> LLMResponse {
        let text = content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
        // Transcript windows are rated concurrently now, so the scripted queue needs a lock.
        if model.contains("haiku") {
            let reply = lock.withLock { haiku.isEmpty ? "[]" : haiku.removeFirst() }
            return LLMResponse(text: reply, usage: LLMUsage(input: 100, output: 20))
        }
        lock.withLock {
            sonnetCalls += 1
            images += content.filter { if case .jpeg = $0 { true } else { false } }.count
        }
        if garbage { return LLMResponse(text: "Sorry, here are my thoughts…", usage: LLMUsage(input: 100, output: 20)) }
        let re = try! NSRegularExpression(pattern: #"Candidate (\d+): ([\d.]+)–([\d.]+)"#)
        let items: [[String: Any]] = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
            let g = { (k: Int) in String(text[Range(m.range(at: k), in: text)!]) }
            let (i, a, b) = (Int(g(1))!, Double(g(2))!, Double(g(3))!)
            let sc = rate(a, b)
            return ["index": i, "score": sc, "reason": sc > 50 ? "No-scope from across the map, crowd erupts" : "Calm walking",
                    "peak": min(max(207.0, a), b), "title": sc > 50 ? "The craziest play" : "Quiet moment \(i)", "description": "d",
                    "hashtags": ["#Shorts"], "tags": ["x"]]
        }
        return LLMResponse(text: String(decoding: try JSONSerialization.data(withJSONObject: items), as: UTF8.self), usage: LLMUsage(input: 5000, output: 300))
    }
}

/// 420 s of per-second signals with a loud, high-motion burst at 205–212 s.
func testSignals(_ duration: Double) -> StorySignals {
    let n = Int(duration)
    return StorySignals(loudness: (0..<n).map { (205...212).contains($0) ? -6 : -30 + Double($0 % 7) },
                        motion: (0..<n).map { (203...214).contains($0) ? 25 : 3 + Double($0 % 5) },
                        scene: (0..<n).map { $0 % 40 == 0 || $0 == 209 ? 60 : 2 })
}

@MainActor
func makeModel(channel: String, llm: RatingLLM = RatingLLM(), minClips: Int = 1) throws -> (AppModel, MockPublisher, Source) {
    useTempRoot()
    let pub = MockPublisher(channelID: channel)
    let model = AppModel(container: try Store.container(inMemory: true), binaries: nil, llm: llm,
                         cost: freshTracker(), ingest: MockIngest(dur: 420), transcriber: MockTranscriber(), clipper: MockClipper(), publisher: pub)
    model.signalProvider = { _, d in testSignals(d) }
    var s = AppSettings()
    s.publishMode = .auto
    s.minGapMinutes = 0
    s.minAutoScore = 70
    s.minClipsPerVideo = minClips
    s.clipStyleID = "none"
    model.settings = s
    let src = Source(url: "https://youtube.com/watch?v=x", info: SourceInfo(title: "Stream \(UUID())", channelID: "UC_me", channelName: "Me", isLive: false, duration: 420))
    model.context.insert(src)
    return (model, pub, src)
}

@MainActor @Suite(.serialized) struct LiveModeTests {
    @Test func pipelineAutoPublishesOnceAndNeverTwice() async throws {
        let (model, pub, src) = try makeModel(channel: "UC_me")
        model.start(src)
        #expect(model.runningSourceID == nil) // blocked: ownership not confirmed
        src.ownershipConfirmedAt = .now
        model.start(src)
        await model.pipeline?.value
        #expect(src.clips.count == 1, "\(model.status)")
        #expect(src.clips.first?.status == .published)
        #expect(await pub.uploads == ["The craziest play #Shorts"])
        // Run again (simulated resume): same moment is a duplicate → no new clip, no new upload.
        src.scoredUntil = 0
        model.start(src)
        await model.pipeline?.value
        let uploadsAfterResume = await pub.uploads.count
        #expect(src.clips.count == 1 && uploadsAfterResume == 1)
        let log = try model.context.fetch(FetchDescriptor<PublishLogEntry>())
        #expect(log.count == 1 && log[0].rightsBasis.hasPrefix("Owner"))
    }

    @Test func foreignChannelNeedsRecordedPermission() async throws {
        let (model, pub, src) = try makeModel(channel: "UC_someone_else")
        src.ownershipConfirmedAt = .now
        model.start(src)
        await model.pipeline?.value
        #expect(src.clips.first?.status == .ready)                 // held for review
        #expect(src.clips.first?.lastError?.contains("rights holder") == true)
        #expect(await pub.uploads.isEmpty)
        await model.publish(src.clips[0])                          // manual publish is blocked too
        #expect(await pub.uploads.isEmpty)
        src.permissionConfirmedAt = .now
        src.permissionNote = "Email from creator"
        await model.publish(src.clips[0])
        #expect(await pub.uploads.count == 1)
        let log = try model.context.fetch(FetchDescriptor<PublishLogEntry>()).first { $0.result == "Published" }
        #expect(log?.rightsBasis.contains("Email from creator") == true)
    }

    /// The loud, high-motion burst wins — not a random or evenly spaced window — and the clip explains why.
    @Test func selectionPicksTheSignalPeakAndExplainsIt() async throws {
        let (model, _, src) = try makeModel(channel: "UC_me")
        src.ownershipConfirmedAt = .now
        model.settings.publishMode = .review
        model.start(src)
        await model.pipeline?.value
        let c = try #require(src.clips.first)
        #expect(c.start <= 207 - SelectionConfig.leadIn && c.end >= 207 + SelectionConfig.payoff)   // peak with lead-in + payoff
        #expect(c.reason.contains("No-scope"))
        #expect((c.signals["vision"] ?? 0) == 95 && (c.signals["audioPeak"] ?? 0) > 80 && (c.signals["motion"] ?? 0) > 80)
        #expect(FileManager.default.fileExists(atPath: src.folder.appendingPathComponent("selection.txt").path))
        #expect(model.candidates.count > 1)
    }

    /// Scoring failure is an error on the run — never a silent fallback to arbitrary clips.
    @Test func scoringFailureStopsWithAnError() async throws {
        let llm = RatingLLM()
        llm.garbage = true
        let (model, pub, src) = try makeModel(channel: "UC_me", llm: llm, minClips: 3)
        src.ownershipConfirmedAt = .now
        model.start(src)
        await model.pipeline?.value
        #expect(llm.sonnetCalls == 2)                                   // one retry
        let uploads = await pub.uploads
        #expect(src.clips.isEmpty && uploads.isEmpty)
        #expect(model.status.hasPrefix("Stopped: Moment rating failed"))
        #expect(model.banners.contains { $0.kind == .error && $0.text.contains("Moment rating failed") })
        // Signal measurement failing is an error too.
        let (m2, _, s2) = try makeModel(channel: "UC_me")
        m2.signalProvider = { _, _ in throw ClipForgeError("ffmpeg exploded") }
        s2.ownershipConfirmedAt = .now
        m2.start(s2)
        await m2.pipeline?.value
        #expect(s2.clips.isEmpty && m2.status == "Stopped: ffmpeg exploded")
    }

    @Test func nothingGoodAndNoMinimumEndsWithVisibleOutcome() async throws {
        let (model, pub, src) = try makeModel(channel: "UC_me", llm: RatingLLM(rate: { _, _ in 20 }), minClips: 0)
        src.ownershipConfirmedAt = .now
        model.start(src)
        await model.pipeline?.value
        #expect(model.stage == .idle && model.runningSourceID == nil && !src.wasRunning)
        #expect(model.lastSourceID == src.id)
        #expect(model.status.contains("none scored"))
        #expect(model.banners.contains { $0.kind == .warning && $0.text.contains("none scored") })
        let uploads = await pub.uploads
        #expect(src.clips.isEmpty && uploads.isEmpty)
    }

    @Test func everyVideoGetsItsBestMomentsEvenWhenWeak() async throws {
        let (model, pub, src) = try makeModel(channel: "UC_me", llm: RatingLLM(rate: { s, e in s <= 205 && e >= 210 ? 45 : 20 }), minClips: 2)
        src.ownershipConfirmedAt = .now
        model.start(src)  // auto mode, minAutoScore 70
        await model.pipeline?.value
        #expect(src.clips.count == 2)
        #expect(src.clips.allSatisfy { $0.status == .ready })        // cut, but held for review
        let uploads = await pub.uploads
        #expect(uploads.isEmpty)
        #expect(model.status == "2 clips ready — open the Clips tab.")
    }

    @Test func runWithClipsReportsThem() async throws {
        let (model, _, src) = try makeModel(channel: "UC_me")
        src.ownershipConfirmedAt = .now
        model.settings.publishMode = .review
        model.start(src)
        await model.pipeline?.value
        #expect(model.status == "1 clip ready — open the Clips tab.")
    }

    @Test func killSwitchHoldsClipsForReview() async throws {
        let (model, pub, src) = try makeModel(channel: "UC_me")
        src.ownershipConfirmedAt = .now
        model.settings.autoPublishKilled = true
        model.start(src)
        await model.pipeline?.value
        #expect(src.clips.first?.status == .ready)
        #expect(await pub.uploads.isEmpty)
    }
}

@Test func publishPolicyLimits() {
    var s = AppSettings()
    s.publishMode = .auto
    s.maxPerHour = 2; s.maxPerDay = 3; s.minAutoScore = 80; s.minGapMinutes = 10
    let now = Date(), id = UUID()
    func past(_ minsAgo: Double, _ start: Double = 0) -> PublishPolicy.Past { .init(date: now.addingTimeInterval(-minsAgo * 60), sourceID: id, start: start, end: start + 30) }
    func check(_ h: [PublishPolicy.Past], score: Int = 90, start: Double = 1000) -> String? {
        PublishPolicy.check(score: score, sourceID: id, start: start, end: start + 30, history: h, settings: s, now: now)
    }
    #expect(check([]) == nil)
    #expect(check([], score: 79) != nil)
    #expect(check([past(5, 100)])?.contains("min since") == true)
    #expect(check([past(20, 100), past(40, 200)])?.contains("Hourly") == true)
    #expect(check([past(70, 100), past(80, 200), past(300, 300)])?.contains("Daily") == true)
    #expect(check([past(120, 1010)])?.contains("Overlaps") == true)
    s.autoPublishKilled = true
    #expect(check([])?.contains("kill switch") == true)
    s.autoPublishKilled = false; s.publishMode = .review
    #expect(check([]) == "Review mode")
}

actor MockLiveIngest: Ingesting {
    func probe(_ url: String) async throws -> SourceInfo { SourceInfo(title: "Live", channelID: "UC_me", channelName: "Me", isLive: true, duration: nil) }
    func downloadVOD(_ url: String, into dir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaSegment { throw ClipForgeError("live") }
    func startLive(_ url: String, into dir: URL, bufferMinutes: Double) -> AsyncStream<MediaSegment> {
        AsyncStream { c in
            for i in 0..<42 { c.yield(MediaSegment(url: dir.appendingPathComponent("seg_\(i).ts"), start: Double(i) * 10, end: Double(i + 1) * 10)) }
            c.finish()
        }
    }
    func stopLive() {}
    func segments(from: Double, to: Double) -> [MediaSegment] { [MediaSegment(url: URL(fileURLWithPath: "/dev/null"), start: from, end: to)] }
}

actor SegmentTranscriber: Transcribing {
    func load(model: String) async throws {}
    func transcribe(_ seg: MediaSegment, progress: (@Sendable (Double) -> Void)?) async throws -> [Word] {
        sampleTranscript.filter { $0.start >= seg.start && $0.start < seg.end }
    }
}

@MainActor @Test func liveModeScoresEveryStepAndCutsOnlyRecordedMoments() async throws {
    useTempRoot()
    let llm = MockLLM(["[]", "[]", stageA, stageB])  // moment at 200 s first appears in the window ending at 270 s
    let pub = MockPublisher(channelID: "UC_me")
    let model = AppModel(container: try Store.container(inMemory: true), binaries: nil, llm: llm, cost: freshTracker(),
                         ingest: MockLiveIngest(), transcriber: SegmentTranscriber(), clipper: MockClipper(), publisher: pub)
    model.settings = AppSettings() // review mode
    let src = Source(url: "https://youtube.com/live/x", info: try await MockLiveIngest().probe(""))
    src.ownershipConfirmedAt = .now
    model.context.insert(src)
    model.start(src)
    await model.pipeline?.value
    // 420 s of stream, scored every 90 s → Stage A at 90,180,270,360 + Stage B once.
    #expect(llm.calls.filter { $0.model == "claude-haiku-5-5" }.count == 4)
    #expect(llm.calls.filter { $0.model == "claude-sonnet-5-5" }.count == 1)
    #expect(src.clips.count == 1 && src.clips[0].status == .ready)  // review queue, not published
    #expect(await pub.uploads.isEmpty)
    #expect(model.stage == .idle && !src.wasRunning)
}
