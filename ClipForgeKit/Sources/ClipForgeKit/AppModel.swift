import Foundation
import Observation
import SwiftData

public struct Banner: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable { case info, warning, error }
    public var id = UUID()
    public var text: String
    public var kind: Kind
}

/// Live-mode orchestrator and view model. Owns the pipeline state machine:
/// idle → watching → scoring → cutting → captioning → queued (→ publishing) → watching …
@MainActor @Observable
public final class AppModel {
    public enum Stage: String, CaseIterable, Sendable { case idle, watching, scoring, cutting, captioning, queued, publishing }

    public var settings = AppSettings.load() { didSet { if settings != oldValue { settings.save() } } }
    public internal(set) var stage: Stage = .idle
    public internal(set) var status = ""
    public internal(set) var progress: Double?
    public internal(set) var transcriptTail = ""
    public internal(set) var candidates: [Highlight] = []
    public internal(set) var sessionCost = 0.0
    public internal(set) var todayCost = 0.0
    public var banners: [Banner] = []
    public var isPaused = false
    public internal(set) var runningSourceID: UUID?

    public let container: ModelContainer
    public let binaries: Binaries?
    let cost: CostTracker
    let voice = VoiceoverService()
    @ObservationIgnored public internal(set) weak var story: StoryModel?
    /// iPhone companion (local network). Off unless enabled in Settings → iPhone.
    @ObservationIgnored var companion: LocalHTTPServer?
    public internal(set) var companionPort: UInt16?
    public internal(set) var companionPairCode: String?
    public internal(set) var companionDevices: [PairedDevice] = PairedDevice.load()
    @ObservationIgnored var companionPairExpires = Date.distantPast
    @ObservationIgnored var companionFailedPairs = 0
    /// Channel Stats: read-only sign-in (separate token) and the latest saved snapshot.
    @ObservationIgnored public let statsAuth = YouTubeAuth.analytics()
    @ObservationIgnored var statsSession: URLSession = .shared
    public var channelStats: ChannelSnapshot? = ChannelAnalytics.latest()
    public var statsSignedIn = false
    public var statsBusy = false
    /// Vlog Editor jobs (JSON per project under Movies/ClipForge/vlogs).
    @ObservationIgnored public private(set) lazy var vlog = VlogModel(binaries: binaries, llm: llm, transcriber: transcriber, cost: cost) { [weak self] in
        self?.settings ?? AppSettings()
    }
    /// Voiceover job progress per clip ("Generating line 2/4…"), cleared when done.
    public internal(set) var voiceJobs: [UUID: String] = [:]
    let highlights: HighlightService
    let llm: LLMClient
    let ingest: (any Ingesting)?
    let transcriber: (any Transcribing)?
    let clipper: (any ClipRendering)?
    let auth: YouTubeAuth
    let publisher: any Publishing
    public internal(set) var youtubeChannel: Channel?
    var pipeline: Task<Void, Never>?
    var words: [Word] = []
    var lastScoredEnd = 0.0
    var budgetBannerShown = false
    /// Pro Editor style for clips cut in the current run (settings default, or picked once per video).
    @ObservationIgnored var runStyleID: String?
    /// Per-second loudness/motion/scene series for a video file. Injectable for tests.
    @ObservationIgnored var signalProvider: @Sendable (URL, Double) async throws -> StorySignals = { _, _ in throw ClipForgeError("ffmpeg is not installed.") }
    /// One decode of the video → signals + 1 fps frames + 16 kHz audio. Without ffmpeg (tests) it wraps `signalProvider`.
    @ObservationIgnored lazy var scanProvider: @Sendable (URL, Double, URL, @escaping @Sendable (Double) -> Void) async throws -> VideoScan = { [signalProvider] url, d, _, _ in
        VideoScan(signals: try await signalProvider(url, d), frames: nil, wav: nil, duration: d)
    }
    /// HUD text + sound events from the scan's frames/audio; empty when ffmpeg is missing. Injectable for tests.
    @ObservationIgnored var eventProvider: @Sendable (VideoScan, URL, @escaping @Sendable (Double) -> Void) async throws -> GameplayScanner.Scan = { _, _, _ in GameplayScanner.Scan() }
    /// Named steps running at the same time ("Transcribing" 0.4, "Scanning video" 0.8) → status text + overall progress.
    @ObservationIgnored var steps: [(name: String, progress: Double)] = []
    // Per-run outcome, reported when the run ends so it never finishes silently.
    @ObservationIgnored var runClips = 0
    @ObservationIgnored var runRenderFailures = 0
    @ObservationIgnored var runScoringErrors = 0
    /// Last source that ran, so its outcome stays visible after the run ends.
    public internal(set) var lastSourceID: UUID?

    public init(container: ModelContainer, binaries: Binaries? = Binaries.detect(), llm: LLMClient = AnthropicClient(),
                cost: CostTracker = CostTracker(), ingest: (any Ingesting)? = nil, transcriber: (any Transcribing)? = nil,
                clipper: (any ClipRendering)? = nil, publisher: (any Publishing)? = nil) {
        self.container = container
        self.binaries = binaries
        self.cost = cost
        self.llm = llm
        highlights = HighlightService(client: llm, cost: cost)
        self.ingest = ingest ?? binaries.map { IngestService(binaries: $0) }
        self.transcriber = transcriber ?? binaries.map { WhisperTranscriber(ffmpeg: $0.ffmpeg) }
        self.clipper = clipper ?? binaries.map { ClipService(ffmpeg: $0.ffmpeg) }
        if let ffmpeg = binaries?.ffmpeg {
            signalProvider = { url, duration in
                let (_, hasAudio) = try await StoryAnalyzer.probe(url, ffmpeg: ffmpeg)
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("cf-signals-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                return try await StoryAnalyzer.signals(url, duration: duration, hasAudio: hasAudio, ffmpeg: ffmpeg, work: work)
            }
            eventProvider = { scan, work, progress in
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                return try await GameplayScanner.scan(scan, work: work, progress: progress)
            }
        }
        auth = YouTubeAuth()
        self.publisher = publisher ?? PublishService(auth: auth)
        if let ffmpeg = binaries?.ffmpeg {
            scanProvider = { url, duration, work, progress in
                let (_, hasAudio) = try await StoryAnalyzer.probe(url, ffmpeg: ffmpeg)
                return try await VideoScanner.run(url, duration: duration, hasAudio: hasAudio, ffmpeg: ffmpeg, work: work, progress: progress)
            }
        }
        Task {
            await refreshCost()
            await reconcileInterruptedUploads()
        }
    }

    var context: ModelContext { container.mainContext }

    /// Story Shorts shares the Claude client, transcriber, budget and settings, but runs its own jobs.
    public func makeStoryModel() -> StoryModel {
        let m = StoryModel(container: container, binaries: binaries, llm: llm, transcriber: transcriber, cost: cost) { [weak self] in
            self?.settings ?? AppSettings()
        }
        m.afterRender = { [weak self] _, rec in await self?.renderRemixClip(rec) }
        story = m
        return m
    }

    public func notify(_ text: String, _ kind: Banner.Kind = .error) {
        if kind == .error { Log.app.error("\(text, privacy: .private)") }
        banners.removeAll { $0.text == text }
        banners.append(Banner(text: text, kind: kind))
    }

    func save() {
        do { try context.save() } catch { Log.app.error("Save failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Sources

    public func addSource(url: String) async throws -> Source {
        guard let ingest else { throw ClipForgeError(Binaries.setupHint) }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed), let host = u.host(), host.contains("youtube.com") || host.contains("youtu.be") else {
            throw ClipForgeError("Enter a YouTube video or live stream URL.")
        }
        let info = try await ingest.probe(trimmed)
        let s = Source(url: trimmed, info: info)
        context.insert(s)
        save()
        return s
    }

    // MARK: Pipeline control

    public func start(_ source: Source) {
        guard runningSourceID == nil else { return notify("Stop the current source first.", .warning) }
        guard ingest != nil, transcriber != nil, clipper != nil else { return notify(Binaries.setupHint, .warning) }
        if let reason = RightsGuard.canProcess(source) { return notify(reason, .warning) }
        runningSourceID = source.id
        source.wasRunning = true
        save()
        words = loadWords(source)
        lastScoredEnd = source.isLive ? 0 : source.scoredUntil
        lastSourceID = source.id
        candidates = []
        runStyleID = settings.clipStyleID == "none" ? nil : settings.clipStyleID
        (runClips, runRenderFailures, runScoringErrors) = (0, 0, 0)
        let id = source.id
        Task { await highlights.reset() }
        pipeline = Task { [weak self] in
            await self?.run(id)
            self?.finish(id)
        }
    }

    public func stop() {
        pipeline?.cancel()
        pipeline = nil
        Task { await ingest?.stopLive() }
        if let id = runningSourceID { finish(id) }
    }

    func finish(_ id: UUID) {
        guard runningSourceID == id else { return }
        if let s = source(id) { s.wasRunning = false; save() }
        runningSourceID = nil
        stage = .idle
        progress = nil
        isPaused = false
    }

    func source(_ id: UUID) -> Source? {
        try? context.fetch(FetchDescriptor<Source>(predicate: #Predicate { $0.id == id })).first
    }

    func waitWhilePaused() async {
        while isPaused, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(500)) }
    }

    func run(_ id: UUID) async {
        guard let ingest, let transcriber, let src = source(id) else { return }
        do {
            stage = .watching
            status = "Loading speech model…"
            try await transcriber.load(model: settings.whisperModel)
            if src.isLive {
                let dir = Paths.dir("sources", id.uuidString, "live-\(Int(Date().timeIntervalSince1970))")
                status = "Connecting to live stream…"
                words = [] // live timeline restarts with each capture session
                for await seg in await ingest.startLive(src.url, into: dir, bufferMinutes: settings.bufferMinutes) {
                    await waitWhilePaused()
                    if Task.isCancelled { break }
                    status = "Live — \(Self.clock(seg.end)) recorded"
                    do {
                        appendWords(try await transcriber.transcribe(seg, progress: nil), source: src)
                    } catch {
                        // One bad segment must not end a live session.
                        Log.app.error("Segment transcription failed: \(error.localizedDescription, privacy: .private)")
                        continue
                    }
                    if seg.end - lastScoredEnd >= settings.stepSeconds {
                        lastScoredEnd = seg.end
                        await scoreAndCut(src, end: seg.end, recordedUntil: seg.end)
                    }
                    stage = .watching
                }
                if !Task.isCancelled { reportOutcome(src, prefix: "Live stream ended or could not be reached. ") }
            } else {
                status = "Downloading…"
                let seg = try await ingest.downloadVOD(src.url, into: src.folder) { p in Task { @MainActor [weak self] in self?.progress = p } }
                src.duration = seg.end
                steps = []
                // The one video decode runs while Whisper transcribes (CPU vs Neural Engine) instead of after it.
                let work = src.folder.appendingPathComponent("selection")
                try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                stage = .scoring
                let scanTask = Task { [scanProvider] in
                    try await scanProvider(seg.url, seg.end, work) { p in Task { @MainActor [weak self] in self?.step("Scanning video", p) } }
                }
                do {
                    if words.last.map({ $0.end < seg.end - 30 }) ?? true {
                        step("Transcribing", 0)
                        let w = try await transcriber.transcribe(seg) { p in Task { @MainActor [weak self] in self?.step("Transcribing", p) } }
                        words = []
                        appendWords(w, source: src)
                        step("Transcribing", nil)
                    }
                } catch { scanTask.cancel(); throw error }
                let scan = try await scanTask.value
                step("Scanning video", nil)
                // Whole-video selection. Errors propagate to the catch below — never a silent fallback.
                let picks = try await selectMoments(src, scan: scan)
                for h in picks where !isDuplicate(h, in: src) {
                    if Task.isCancelled { break }
                    await waitWhilePaused()
                    await cut(h, src)
                }
                src.scoredUntil = seg.end
                save()
                if Task.isCancelled { status = "Stopped" } else { reportOutcome(src) }
            }
        } catch is CancellationError {
            status = "Stopped"
        } catch HighlightError.budgetReached {
            notify("Daily API budget reached — moment scoring stopped. Raise the budget in Settings → Highlights.")
            status = "Stopped: daily API budget reached"
        } catch {
            notify(error.localizedDescription)
            status = "Stopped: \(error.localizedDescription)"
        }
    }

    /// Shows every step that is running ("Transcribing 45% · Scanning video 80%"); nil removes the step.
    func step(_ name: String, _ p: Double?) {
        if let p { if let i = steps.firstIndex(where: { $0.name == name }) { steps[i].progress = p } else { steps.append((name, p)) } }
        else { steps.removeAll { $0.name == name } }
        guard !steps.isEmpty else { return }
        status = steps.map { "\($0.name) \(Int(($0.progress * 100).rounded()))%" }.joined(separator: " · ")
        progress = steps.map(\.progress).reduce(0, +) / Double(steps.count)
    }

    /// Whole-video moment selection. After one scan: on-screen text + sounds, the transcript rating and Claude watching
    /// the whole video run at the same time; then the best windows get a Haiku first look and a Sonnet rating.
    func selectMoments(_ src: Source, scan: VideoScan) async throws -> [Highlight] {
        stage = .scoring
        let work = src.folder.appendingPathComponent("selection")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let sig = scan.signals, duration = scan.duration
        let report: @Sendable (String) -> @Sendable (Double) -> Void = { name in { p in Task { @MainActor [weak self] in self?.step(name, p) } } }
        async let gameScan = eventProvider(scan, work, report("On-screen text & sounds"))
        async let watched = VideoWatcher.watch(scan, client: llm, cost: cost, settings: settings, progress: report("Claude watching the video"))
        async let rated = rateTranscript(duration: duration, progress: report("Rating what's said"))
        let (g, cells, transcriptRatings) = try await (gameScan, watched, rated)
        steps = []
        await refreshCost()
        let genre = GameplayScanner.genre(g, setting: settings.gameGenre)
        let events = GameplayScanner.events(g, genre: genre)
        let watch = VideoWatcher.signal(cells, duration: duration)
        var all = MomentFinder.windows(sig, words: words, transcriptRatings: transcriptRatings, duration: duration, events: events,
                                       weights: genre.weights, watch: watch)
        guard !all.isEmpty else { throw ClipForgeError("Couldn't measure this video (no audio/visual signal). Is the file readable?") }
        for i in all.indices {
            let seen = VideoWatcher.summary(cells, from: all[i].start, to: all[i].end)
            if !seen.isEmpty { all[i].events = ([all[i].events, "Seen: " + seen].filter { !$0.isEmpty }).joined(separator: "\n") }
        }
        var top = MomentFinder.top(all, count: SelectionConfig.topForTriage)
        if scan.frames != nil {
            for i in top.indices { top[i].frames = scan.frames(from: top[i].start, to: top[i].end, count: SelectionConfig.triageFrames) }
        } else if let ffmpeg = binaries?.ffmpeg {
            let moments = top.map { StoryMoment(index: $0.index, start: $0.start, end: $0.end, loudness: 0, motion: 0, scene: 0, speech: 0) }
            let framed = try await StoryAnalyzer.frames(moments, video: URL(fileURLWithPath: src.folder.appendingPathComponent("source.mp4").path), ffmpeg: ffmpeg,
                                                        work: work, perMoment: SelectionConfig.triageFrames)
            for i in top.indices { top[i].frames = framed[i].frames }
        }
        status = "First look at \(top.count) moments (\(genre.label))…"
        progress = 0.85
        top = try await MomentFinder.triage(top, client: llm, cost: cost, settings: settings)
        status = "Rating the top \(top.count) moments with Claude (frames + what was seen + transcript)…"
        progress = 0.93
        top = try await MomentFinder.rate(top, words: words, client: llm, cost: cost, settings: settings)
        await refreshCost()
        let picks = MomentFinder.pick(top, words: words, cuts: MomentFinder.cuts(sig), duration: duration, settings: settings)
        await chooseRunStyle(src)
        candidates = top.map { c in
            var h = Highlight(start: c.start, end: c.end, title: c.title, hook: "", score: Int(c.preScore * 100), reason: c.reason)
            h.finalScore = Int(c.final.rounded())
            return h
        }
        let table = MomentFinder.table(top)
        Log.ai.info("Moment selection for \(src.title, privacy: .private):\n\(table, privacy: .public)")
        try? ("Genre: \(genre.label) (\(settings.gameGenre)) · \(events.count) events · \(cells.count) watched cells\nSignal weights: " + genre.weights.map { "\($0.key) \($0.weight)" }.joined(separator: ", ")
              + " · final = \(SelectionConfig.signalShare) × signals + \(1 - SelectionConfig.signalShare) × vision\n\n" + table)
            .write(to: src.folder.appendingPathComponent("selection.txt"), atomically: true, encoding: .utf8)
        if let d = try? JSONEncoder().encode(top) { try? d.write(to: src.folder.appendingPathComponent("selection.json")) }
        if let d = try? JSONEncoder().encode(cells) { try? d.write(to: src.folder.appendingPathComponent("watched.json")) }
        progress = nil
        return picks
    }

    /// Haiku rates the transcript in non-overlapping windows, several at once (the live path still steps window by window).
    func rateTranscript(duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [Highlight] {
        guard words.count > 20 else { return [] }
        await highlights.reset()
        let len = SelectionConfig.transcriptWindow, step = SelectionConfig.transcriptStep
        var ends = Array(stride(from: min(len, duration), to: duration, by: step))
        if ends.last.map({ $0 < duration }) ?? true { ends.append(duration) }
        let (w, s, h) = (words, settings, highlights)
        var finished = 0
        try await withThrowingTaskGroup(of: Void.self) { g in
            var next = 0
            func add() { guard next < ends.count else { return }; let e = ends[next]; next += 1; g.addTask { _ = try await h.scoreWindow(w, end: e, settings: s, window: len) } }
            for _ in 0..<SelectionConfig.transcriptConcurrency { add() }
            while try await g.next() != nil { finished += 1; progress(Double(finished) / Double(ends.count)); add() }
        }
        return await h.candidates
    }

    func appendWords(_ w: [Word], source: Source) {
        words += w
        transcriptTail = Array(words.suffix(80)).joinedText
        if let d = try? JSONEncoder().encode(words) { try? d.write(to: source.folder.appendingPathComponent("words.json")) }
        try? settings.whisperModel.write(to: source.folder.appendingPathComponent("words.model"), atomically: true, encoding: .utf8)
    }

    func loadWords(_ source: Source) -> [Word] {
        guard !source.isLive, let d = try? Data(contentsOf: source.folder.appendingPathComponent("words.json")) else { return [] }
        // A transcript from another (older) speech model is redone with the current one.
        let model = try? String(contentsOf: source.folder.appendingPathComponent("words.model"), encoding: .utf8)
        guard model == settings.whisperModel else { return [] }
        // Older transcripts may still contain Whisper's non-speech tags.
        return WhisperTranscriber.speechOnly((try? JSONDecoder().decode([Word].self, from: d)) ?? [])
    }

    /// Returns false when scoring should stop (budget reached).
    @discardableResult
    func scoreAndCut(_ src: Source, end: Double, recordedUntil: Double) async -> Bool {
        stage = .scoring
        do {
            try await highlights.scoreWindow(words, end: end, settings: settings)
            try await highlights.rank(words, settings: settings)
            budgetBannerShown = false
        } catch HighlightError.budgetReached {
            if !budgetBannerShown { notify("Daily API budget reached — highlight scoring is paused until tomorrow or until you raise the budget.", .warning) }
            budgetBannerShown = true
            await refreshCost()
            return !src.isLive ? false : true
        } catch {
            runScoringErrors += 1
            notify("Highlight scoring failed: \(error.localizedDescription)")
        }
        await refreshCost()
        candidates = await highlights.candidates
        for h in candidates where h.finalScore != nil && h.effectiveScore >= settings.stageBThreshold
            && h.end <= recordedUntil && !isDuplicate(h, in: src) {
            if Task.isCancelled { break }
            await cut(h, src)
        }
        return true
    }

    func cut(_ h: Highlight, _ src: Source) async {
        let rec = ClipRecord(h, style: settings.captionStyle)
        rec.source = src
        rec.styleID = runStyleID
        // The style's caption look becomes the clip's own; after that, the clip's caption style is the source of truth.
        if let p = runStyleID.flatMap(StyleLibrary.profile) { rec.captionStyle = p.captions.style }
        context.insert(rec)
        save()
        await render(rec, words: words)
        if rec.status == .failed { runRenderFailures += 1 } else { runClips += 1 }
        await afterRender(rec)
    }

    /// Already cut, or the user rejected (and deleted) this moment before.
    func isDuplicate(_ h: Highlight, in src: Source) -> Bool {
        func overlaps(_ a: Double, _ b: Double) -> Bool { HighlightLogic.overlapRatio(Highlight(start: a, end: b, title: "", hook: "", score: 0, reason: ""), h) > 0.5 }
        return src.clips.contains { $0.id == h.id || overlaps($0.start, $0.end) }
            || src.rejectedRanges.contains { $0.count == 2 && overlaps($0[0], $0[1]) }
    }

    func render(_ rec: ClipRecord, words: [Word]) async {
        if rec.storyJobID != nil { return await renderRemixClip(rec) }
        guard let clipper, let ingest, let src = rec.source else { return }
        rec.status = .rendering
        stage = .cutting
        status = "Cutting & captioning “\(rec.title)”…"
        let from = rec.start, to = rec.end   // padding was applied when the boundaries were snapped
        var segs = await ingest.segments(from: from, to: to)
        if segs.isEmpty, !src.isLive, let d = src.duration {
            segs = [MediaSegment(url: src.folder.appendingPathComponent("source.mp4"), start: 0, end: d)]
        }
        do {
            stage = .captioning
            // Captions edited in review replace the transcript where they cover it.
            let captions = rec.captionWords.map { cw -> [Word] in
                guard let lo = cw.first?.start, let hi = cw.last?.end else { return words }
                return (words.filter { $0.end <= lo || $0.start >= hi } + cw).sorted { $0.start < $1.start }
            } ?? words
            let mix = voiceMix(for: rec)
            // With a voiceover the timeline must stay exactly [start, end] so the lines stay in sync (no cut snapping).
            let look = clipLook(for: rec)
            let r = try await clipper.render(start: from, end: to, keep: mix == nil ? rec.keep : from...to, from: segs, words: captions,
                                             style: rec.captionStyle, framing: rec.framing, voice: mix, look: look,
                                             to: src.folder.appendingPathComponent("clips"))
            rec.editorNotes = look.map { editorNotes(rec, $0) }
            rec.framingSummary = r.framingSummary
            // Each render has its own file; drop the one it replaces (video, subtitles, framing plan).
            for old in [rec.videoPath, rec.srtPath, rec.videoPath.map { ($0 as NSString).deletingPathExtension + ".framing.json" }].compactMap({ $0 })
            where old != r.video.path && old != r.srt.path && old.hasPrefix(src.folder.path) {
                try? FileManager.default.removeItem(atPath: old)
            }
            rec.videoPath = r.video.path
            rec.srtPath = r.srt.path
            rec.start = r.start
            rec.end = r.end
            rec.status = .ready
            rec.lastError = nil
            rec.failure = nil
        } catch {
            rec.status = .failed
            rec.failure = .render
            rec.lastError = error.localizedDescription
        }
        save()
        stage = .queued
    }

    // MARK: Clip editing

    /// Re-render after a trim / caption / style edit. A manual trim is respected exactly (no cut snapping).
    public func rerender(_ rec: ClipRecord, start: Double, end: Double, style: CaptionStyle) async {
        guard end - start >= 3, end - start <= settings.hardMaxSeconds else {
            return notify("Clips must be between 3 s and \(Int(settings.hardMaxSeconds)) s.", .warning)
        }
        if start != rec.start || end != rec.end { rec.coreStart = start; rec.coreEnd = end }
        rec.start = start
        rec.end = end
        rec.captionStyle = style
        await render(rec, words: transcript(for: rec))
        if runningSourceID == nil { stage = .idle }
    }

    func transcript(for rec: ClipRecord) -> [Word] {
        rec.source.map { $0.id == runningSourceID ? words : loadWords($0) } ?? []
    }

    /// Debug render: the clip's source range with detected subjects, crop window and shots drawn on it.
    public func debugPreview(_ rec: ClipRecord) async -> URL? {
        guard let clipper, let ingest, let src = rec.source else { return nil }
        var segs = await ingest.segments(from: rec.start, to: rec.end)
        if segs.isEmpty, !src.isLive, let d = src.duration { segs = [MediaSegment(url: src.folder.appendingPathComponent("source.mp4"), start: 0, end: d)] }
        do {
            return try await clipper.debugPreview(start: rec.start, end: rec.end, from: segs, words: transcript(for: rec),
                                                  framing: rec.framing, to: src.folder.appendingPathComponent("clips"))
        } catch {
            notify("Debug preview failed: \(error.localizedDescription)")
            return nil
        }
    }

    public func setStatus(_ rec: ClipRecord, _ s: ClipStatus) {
        rec.status = s
        save()
    }

    public func exportAll(to dir: URL) -> Int {
        let recs = (try? context.fetch(FetchDescriptor<ClipRecord>())) ?? []
        var n = 0
        for r in recs where [.ready, .approved, .published].contains(r.status) {
            for p in [r.videoPath, r.srtPath].compactMap({ $0 }) {
                let src = URL(fileURLWithPath: p), dst = dir.appendingPathComponent(src.lastPathComponent)
                try? FileManager.default.removeItem(at: dst)
                if (try? FileManager.default.copyItem(at: src, to: dst)) != nil, p == r.videoPath { n += 1 }
            }
        }
        return n
    }

    func refreshCost() async {
        sessionCost = await cost.sessionCost
        todayCost = await cost.todayCost
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension AppModel {
    /// Every finished run ends with a visible outcome, including "nothing found".
    func reportOutcome(_ src: Source, prefix: String = "") {
        let msg: String
        if runClips > 0 {
            msg = "\(runClips) clip\(runClips == 1 ? "" : "s") ready — open the Clips tab."
        } else if runRenderFailures > 0 {
            msg = "\(runRenderFailures) clip\(runRenderFailures == 1 ? "" : "s") failed to render — open the Clips tab for details."
        } else if runScoringErrors > 0 {
            msg = "Highlight scoring failed (see the error above), so no clips were cut."
        } else if candidates.isEmpty {
            msg = "Claude found no moment worth clipping, so nothing was cut. Scoring reads the transcript (\(words.count) words here); music-heavy or very short videos often have nothing above the cut-off."
        } else {
            msg = "\(candidates.count) moment\(candidates.count == 1 ? "" : "s") rated, but none scored \(SelectionConfig.extraClipMinScore)+ and “Always cut the best N moments” is 0. Raise it in Settings → Clips to cut the best ones anyway."
        }
        status = prefix + msg
        notify("“\(src.title)”: " + prefix + msg, runClips > 0 ? .info : .warning)
    }

    /// Auto-publish gate: limits first, then RightsGuard. Anything held stays in the review queue.
    func afterRender(_ rec: ClipRecord) async {
        guard rec.status == .ready, settings.publishMode == .auto, let src = rec.source else { return }
        let history = ((try? context.fetch(FetchDescriptor<ClipRecord>())) ?? []).compactMap { c in
            c.publishedAt.map { PublishPolicy.Past(date: $0, sourceID: c.source?.id, start: c.start, end: c.end) }
        }
        if let reason = PublishPolicy.check(score: rec.effectiveScore, sourceID: src.id, start: rec.start, end: rec.end, history: history, settings: settings) {
            rec.lastError = "Held for review: \(reason)"
            save()
            return
        }
        guard let channel = try? await publisher.channel() else {
            rec.lastError = "Held for review: not signed in to YouTube"
            return save()
        }
        if let reason = RightsGuard.canPublish(src, to: channel) {
            rec.lastError = "Held for review: \(reason)"
            return save()
        }
        await publish(rec, auto: true)
    }
}

extension AppModel {
    /// Auto style for this video's clips: one cheap Haiku pick. A failed pick leaves clips unstyled (and says so) —
    /// it never invents a look.
    func chooseRunStyle(_ src: Source) async {
        guard settings.clipStyleID == nil else { return }
        var o = StoryOptions()
        o.gameName = src.title
        o.style = .story
        do {
            runStyleID = try await EditPlanner.autoPick(o, words: words, profiles: StyleLibrary.all(), client: llm, cost: cost, settings: settings).id
        } catch {
            runStyleID = nil
            notify("Couldn't pick an editing style automatically (\(error.localizedDescription)); clips use the plain look.", .info)
        }
    }

    /// The clip's style profile → render look. Intensity scales punch-ins and sound effects.
    func clipLook(for rec: ClipRecord) -> ClipLook? {
        guard let id = rec.styleID, let p = StyleLibrary.profile(id), rec.storyJobID == nil else { return nil }
        let i = settings.clipIntensity
        let selected = abs(rec.coreEnd - rec.coreStart - SelectionConfig.leadIn - SelectionConfig.payoff) < 0.6
        let peak = rec.coreEnd > rec.coreStart ? (selected ? rec.coreStart + SelectionConfig.leadIn : (rec.coreStart + rec.coreEnd) / 2) - rec.start : nil
        // The clip's caption style wins (it's what Review shows and lets you change). Uppercase is part of the profile's
        // own caption look, so it only applies while the clip still uses that style.
        return ClipLook(captionStyle: rec.captionStyle, uppercase: p.captions.uppercase && rec.captionStyle == p.captions.style, pop: p.captions.animation == "pop",
                        grade: EditPlanner.grade(p.color),
                        punchAt: p.motion.punchInsPer10s * (0.4 + i) >= 0.5 ? peak : nil,
                        punchScale: p.motion.punchInScale + 0.05 * i,
                        hitAt: p.sound.hitsOnImpacts && p.sound.sfxDensity * (0.3 + i) >= 0.3 ? peak : nil,
                        cutFillers: p.pacing.cutFillers)
    }

    func editorNotes(_ rec: ClipRecord, _ l: ClipLook) -> String {
        let name = rec.styleID.flatMap(StyleLibrary.profile)?.name ?? "—"
        var lines = ["Style: \(name) (intensity \(Int(settings.clipIntensity * 100))%)."]
        if let p = l.punchAt { lines.append(String(format: "Punch-in to %.2f× on the peak at %.1f s to sell the moment.", l.punchScale, p)) }
        if let h = l.hitAt { lines.append(String(format: "Impact hit at %.1f s.", h)) }
        if l.cutFillers { lines.append("Cut filler words and pauses over 0.7 s for pace.") }
        lines.append("\(l.captionStyle.label) captions\(l.pop ? " with pop-in words" : "")\(l.uppercase ? ", uppercase" : ""); \(l.grade.isEmpty ? "neutral" : "graded") color.")
        return lines.joined(separator: "\n")
    }
}

