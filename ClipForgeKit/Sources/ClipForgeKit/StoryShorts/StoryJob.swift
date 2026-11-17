import Foundation
import Observation
import SwiftData

public enum StoryStage: String, Codable, Sendable, CaseIterable {
    case queued, importing, analyzing, picking, writing, captioning, music, rendering, done, failed

    /// The stages a job walks through, in order.
    public static let pipeline: [StoryStage] = [.importing, .analyzing, .picking, .writing, .captioning, .music, .rendering]

    public var label: String {
        switch self {
        case .queued: "Queued"
        case .importing: "Uploading"
        case .analyzing: "Analyzing"
        case .picking: "Picking moments"
        case .writing: "Planning edit"
        case .captioning: "Captioning"
        case .music: "Adding music"
        case .rendering: "Rendering"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
    var order: Int { Self.pipeline.firstIndex(of: self) ?? (self == .done ? 99 : -1) }
}

@Model public final class StoryJob {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var name: String
    public var videoPath: String
    public var optionsData: Data
    public var stageRaw: String
    /// Where the next run starts (nil = from the beginning). Lets Retry/Re-render skip finished work.
    public var resumeFromRaw: String?
    public var failedStageRaw: String?
    public var errorMessage: String?
    public var duration: Double = 0
    public var hasAudio: Bool = true
    public var momentsData: Data?
    public var storyboardData: Data?
    public var musicData: Data?
    public var musicOffset: Double = 0
    public var outputPath: String?
    /// The review-flow clip made from this job's output (approve / publish / voiceover / timeline edits).
    public var clipID: UUID?

    public init(video: URL, options: StoryOptions) {
        id = UUID(); createdAt = .now; name = video.deletingPathExtension().lastPathComponent; videoPath = video.path
        optionsData = (try? JSONEncoder().encode(options)) ?? Data(); stageRaw = StoryStage.queued.rawValue
    }

    public var stage: StoryStage {
        get { StoryStage(rawValue: stageRaw) ?? .failed }
        set { stageRaw = newValue.rawValue }
    }
    public var failedStage: StoryStage? { failedStageRaw.flatMap(StoryStage.init(rawValue:)) }
    public var options: StoryOptions {
        get { (try? JSONDecoder().decode(StoryOptions.self, from: optionsData)) ?? .init() }
        set { optionsData = (try? JSONEncoder().encode(newValue)) ?? optionsData }
    }
    public var storyboard: Storyboard? {
        get { storyboardData.flatMap { try? JSONDecoder().decode(Storyboard.self, from: $0) } }
        set { storyboardData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    public var music: MusicTrack? {
        get { musicData.flatMap { try? JSONDecoder().decode(MusicTrack.self, from: $0) } }
        set { musicData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    var moments: [StoryMoment] {
        get { momentsData.flatMap { try? JSONDecoder().decode([StoryMoment].self, from: $0) } ?? [] }
        set { momentsData = try? JSONEncoder().encode(newValue) }
    }
    public var video: URL { URL(fileURLWithPath: videoPath) }
    public var outputURL: URL? { outputPath.map(URL.init(fileURLWithPath:)) }
    public var folder: URL { Paths.dir("stories", id.uuidString) }
    public var isActive: Bool { ![.done, .failed].contains(stage) }
}

/// Runs Story Shorts jobs one at a time in the background. Separate from the highlight pipeline (AppModel).
@MainActor @Observable
public final class StoryModel {
    public static let pageID = UUID(uuidString: "5701E5A0-0000-4000-8000-000000000001")!

    public let container: ModelContainer
    let binaries: Binaries?
    let llm: LLMClient
    let transcriber: (any Transcribing)?
    let cost: CostTracker
    let settings: @MainActor () -> AppSettings
    public internal(set) var runningJobID: UUID?
    public internal(set) var progress: Double?
    @ObservationIgnored var worker: Task<Void, Never>?
    @ObservationIgnored var current: Task<Void, Never>?
    @ObservationIgnored var abortReason: String?

    public init(container: ModelContainer, binaries: Binaries?, llm: LLMClient, transcriber: (any Transcribing)?,
                cost: CostTracker, settings: @escaping @MainActor () -> AppSettings) {
        self.container = container; self.binaries = binaries; self.llm = llm
        self.transcriber = transcriber; self.cost = cost; self.settings = settings
        MusicLibrary.prepareFolders()
        // A job that was mid-stage when the app quit can't be trusted; make it retryable.
        for j in jobs() where j.isActive && j.stage != .queued {
            fail(j, at: j.stage, "Interrupted when ClipForge quit. Press Retry to continue.")
        }
        pump()
    }

    var context: ModelContext { container.mainContext }
    func save() { try? context.save() }
    func jobs() -> [StoryJob] { (try? context.fetch(FetchDescriptor<StoryJob>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [] }

    // MARK: Public actions

    @discardableResult
    public func create(video: URL, options: StoryOptions) throws -> StoryJob {
        guard StoryConfig.videoTypes.contains(video.pathExtension.lowercased()) else {
            throw ClipForgeError("Pick an mp4, mov or mkv gameplay video.")
        }
        let job = StoryJob(video: video, options: options)
        context.insert(job)
        save()
        pump()
        return job
    }

    /// Continue from the stage that failed, keeping earlier results.
    public func retry(_ job: StoryJob) { enqueue(job, from: job.failedStage ?? .importing) }
    /// After editing captions, title or music: redo captions → music → render (no new Claude call).
    public func rerender(_ job: StoryJob) { enqueue(job, from: .captioning) }
    /// After changing length/tone/game: ask Claude for a new storyboard.
    public func rewrite(_ job: StoryJob) { job.music = nil; enqueue(job, from: .writing) }

    public func cancel(_ job: StoryJob) {
        if job.id == runningJobID { abortReason = "Cancelled."; current?.cancel(); fail(job, at: job.stage, "Cancelled.") }
        else if job.stage == .queued { fail(job, at: .queued, "Cancelled.") }
    }

    public func delete(_ job: StoryJob) {
        guard job.id != runningJobID else { return }
        try? FileManager.default.removeItem(at: job.folder)
        context.delete(job)
        save()
    }

    func enqueue(_ job: StoryJob, from: StoryStage) {
        guard job.id != runningJobID else { return }
        job.resumeFromRaw = from.rawValue
        job.errorMessage = nil
        job.failedStageRaw = nil
        job.stage = .queued
        save()
        pump()
    }

    func fail(_ job: StoryJob, at s: StoryStage, _ message: String) {
        job.failedStageRaw = (s == .queued || s == .failed ? job.failedStage ?? .importing : s).rawValue
        job.stage = .failed
        job.errorMessage = message
        save()
    }

    // MARK: Worker

    func pump() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let job = self.jobs().first(where: { $0.stage == .queued }) {
                await self.runWithWatchdog(job)
            }
            self?.worker = nil
        }
    }

    func runWithWatchdog(_ job: StoryJob) async {
        runningJobID = job.id
        abortReason = nil
        let task = Task { await self.process(job) }
        current = task
        await task.value
        current = nil
        runningJobID = nil
        progress = nil
    }

    /// Runs `body` as stage `s`. A watchdog fails the job at the deadline even if a subsystem ignores cancellation.
    func stage(_ job: StoryJob, _ s: StoryStage, _ body: () async throws -> Void) async throws {
        try Task.checkCancellation()
        job.stage = s
        progress = nil
        save()
        let limit = StoryConfig.timeouts[s] ?? 600
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: .seconds(limit))
            guard let self, self.runningJobID == job.id, job.stage == s else { return }
            self.abortReason = "\(s.label) took longer than \(Int(limit / 60)) min and was stopped."
            self.fail(job, at: s, self.abortReason!)
            self.current?.cancel()
        }
        defer { watchdog.cancel() }
        do { try await body() } catch {
            if job.stage != .failed { fail(job, at: s, abortReason ?? "\(s.label) failed: \(error.localizedDescription)") }
            throw error
        }
        if job.stage == .failed { throw CancellationError() } // watchdog fired while a non-cancellable step finished
    }

    func process(_ job: StoryJob) async {
        guard let bin = binaries else { return fail(job, at: .importing, Binaries.setupHint) }
        let from = job.resumeFromRaw.flatMap(StoryStage.init(rawValue:)) ?? .importing
        let work = job.folder
        let wordsURL = work.appendingPathComponent("words.json")
        var words = (try? JSONDecoder().decode([Word].self, from: Data(contentsOf: wordsURL))) ?? []
        do {
            if from.order <= StoryStage.importing.order {
                try await stage(job, .importing) {
                    guard FileManager.default.isReadableFile(atPath: job.videoPath) else { throw ClipForgeError("The video file is missing or unreadable: \(job.videoPath)") }
                    (job.duration, job.hasAudio) = try await StoryAnalyzer.probe(job.video, ffmpeg: bin.ffmpeg)
                    guard job.duration >= 5 else { throw ClipForgeError("The video is shorter than 5 seconds.") }
                }
            }
            if from.order <= StoryStage.analyzing.order {
                try await stage(job, .analyzing) {
                    // The signal pass (a full decode) and transcription are independent: run them side by side.
                    let (video, duration, hasAudio) = (job.video, job.duration, job.hasAudio)
                    async let signals = StoryAnalyzer.signals(video, duration: duration, hasAudio: hasAudio, ffmpeg: bin.ffmpeg, work: work)
                    words = []
                    if job.hasAudio, let transcriber {
                        try await transcriber.load(model: settings().whisperModel)
                        words = try await transcriber.transcribe(MediaSegment(url: job.video, start: 0, end: job.duration)) { p in
                            Task { @MainActor [weak self] in self?.progress = p * 0.7 }
                        }
                    }
                    try JSONEncoder().encode(words).write(to: wordsURL)
                    progress = 0.75
                    let sig = try await signals
                    let style = job.options.style
                    let moments = style.isRemix
                        ? StoryAnalyzer.candidates(sig, words: words, duration: job.duration, count: StoryConfig.remixCandidates,
                                                   window: style == .montage ? 8 : 12, buckets: StoryConfig.remixBuckets)
                        : StoryAnalyzer.candidates(sig, words: words, duration: job.duration)
                    guard !moments.isEmpty else { throw ClipForgeError("Couldn't find any usable moments in this video.") }
                    job.moments = moments
                }
            }
            if from.order <= StoryStage.picking.order {
                try await stage(job, .picking) {
                    let per = job.options.style.isRemix ? StoryConfig.remixFramesPerMoment : StoryConfig.framesPerMoment
                    job.moments = try await StoryAnalyzer.frames(job.moments, video: job.video, ffmpeg: bin.ffmpeg, work: work, perMoment: per)
                }
            }
            if from.order <= StoryStage.writing.order {
                try await stage(job, .writing) {
                    let o = job.options, s = settings()
                    // Pro Editor: chosen style, or Auto (cheap pick) — never a random edit.
                    let profile: StyleProfile
                    if let id = o.styleID {
                        guard let p = StyleLibrary.profile(id) else { throw ClipForgeError("Style “\(id)” isn't installed anymore. Pick another style.") }
                        profile = p
                    } else {
                        profile = try await EditPlanner.autoPick(o, words: words, profiles: StyleLibrary.all(), client: llm, cost: cost, settings: s)
                    }
                    var sb = try await StoryWriter.write(client: llm, cost: cost, settings: s, options: o, moments: job.moments,
                                                         words: words, duration: job.duration, profile: profile)
                    sb = try await EditPlanner.critique(sb, profile: profile, options: o, moments: job.moments, duration: job.duration,
                                                        client: llm, cost: cost, settings: s)
                    sb = StoryWriter.fit(sb, target: o.targetSeconds, moments: job.moments, duration: job.duration, style: o.style, vertical: o.format == .vertical)
                    sb = EditPlanner.applyIntensity(sb, profile: profile, intensity: o.intensity)
                    sb.styleID = profile.id
                    job.storyboard = sb
                }
            }
            guard var sb = job.storyboard else { throw ClipForgeError("No storyboard yet — press Retry.") }
            var overlays: StoryRenderer.Overlays?
            try await stage(job, .captioning) {
                overlays = try StoryRenderer.captions(sb, words: words, options: job.options, work: work)
            }
            try await stage(job, .music) {
                let track: MusicTrack
                if let chosen = job.music, FileManager.default.fileExists(atPath: chosen.path) { track = chosen }
                else { track = try await MusicLibrary.pick(mood: sb.styleID.flatMap(StyleLibrary.profile)?.sound.musicMood ?? sb.tone, ffmpeg: bin.ffmpeg) }
                let grid = try await MusicLibrary.beats(track.url, ffmpeg: bin.ffmpeg)
                job.music = track
                job.musicOffset = grid.first ?? 0
                let snapped = MusicLibrary.snap(sb.beats, grid: grid.map { $0 - job.musicOffset }, duration: job.duration,
                                                maxShift: job.options.style == .montage ? StoryConfig.montageBeatSnap : StoryConfig.beatSnap)
                if snapped != sb.beats {
                    sb.beats = snapped
                    job.storyboard = sb
                    overlays = try StoryRenderer.captions(sb, words: words, options: job.options, work: work)
                }
            }
            try await stage(job, .rendering) {
                let tmp = work.appendingPathComponent("render-tmp.mp4"), out = work.appendingPathComponent("story-short.mp4")
                try await StoryRenderer.render(sb, video: job.video, hasAudio: job.hasAudio, words: words, options: job.options,
                                               overlays: overlays!, music: job.music, musicOffset: job.musicOffset,
                                               out: tmp, ffmpeg: bin.ffmpeg, work: work)
                try? FileManager.default.removeItem(at: out)
                try FileManager.default.moveItem(at: tmp, to: out)
                job.outputPath = out.path
            }
            job.stage = .done
            job.resumeFromRaw = nil
            save()
            await linkClip(job, storyboard: sb)
        } catch {
            // `stage` already recorded the failure; this covers errors outside a stage.
            if job.stage != .failed { fail(job, at: job.stage, error.localizedDescription) }
        }
    }

    /// Hook for the app model: re-applies a clip's voiceover after the remix is re-rendered.
    @ObservationIgnored public var afterRender: (@MainActor (StoryJob, ClipRecord) async -> Void)?

    /// Every finished remix/story becomes (or updates) a clip in the review flow: Review Queue, review screen with
    /// the timeline, approve / download / publish. Its source is the local file, which you confirmed owning.
    func linkClip(_ job: StoryJob, storyboard sb: Storyboard) async {
        guard let out = job.outputPath else { return }
        let clips = (try? context.fetch(FetchDescriptor<ClipRecord>())) ?? []
        let rec: ClipRecord
        if let id = job.clipID, let existing = clips.first(where: { $0.id == id }) { rec = existing } else {
            let fileURL = "file://" + job.videoPath
            let src = ((try? context.fetch(FetchDescriptor<Source>())) ?? []).first { $0.url == fileURL }
                ?? Source(url: fileURL, info: SourceInfo(title: job.name, channelID: "", channelName: "Local file", isLive: false, duration: job.duration))
            if src.modelContext == nil { context.insert(src) }
            src.ownershipConfirmedAt = src.ownershipConfirmedAt ?? job.createdAt
            src.duration = job.duration
            var h = Highlight(start: 0, end: sb.outputDuration, title: sb.title, hook: sb.beats.first?.caption ?? "", score: 0,
                              reason: "\(job.options.style.label) from \(sb.beats.count) moments across the video")
            h.description = sb.description + "\n\n" + sb.hashtags.joined(separator: " ")
            rec = ClipRecord(h, style: job.options.captionStyle)
            rec.source = src
            rec.storyJobID = job.id
            context.insert(rec)
            job.clipID = rec.id
        }
        rec.end = sb.outputDuration
        rec.videoPath = out
        rec.srtPath = nil
        rec.status = .ready
        rec.lastError = nil
        save()
        await afterRender?(job, rec)
    }

    public func job(_ id: UUID?) -> StoryJob? { id.flatMap { id in jobs().first { $0.id == id } } }

    /// Copies the short (plus a text file with title, description and hashtags) to `url`.
    public func export(_ job: StoryJob, to url: URL) throws {
        guard let src = job.outputURL, let sb = job.storyboard else { throw ClipForgeError("Render the short first.") }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: src, to: url)
        let meta = "\(sb.title)\n\n\(sb.description)\n\n\(sb.hashtags.joined(separator: " "))\n"
        try meta.write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }
}
