import Foundation
import MapKit
import Observation

public enum VlogStage: String, Codable, Sendable {
    case queued, importing, analyzing, planning, rendering, done, failed
    public var label: String {
        ["queued": "Queued", "importing": "Importing & making proxies", "analyzing": "Checking shots", "planning": "Planning edit",
         "rendering": "Rendering", "done": "Done", "failed": "Failed"][rawValue]!
    }
}

public struct VlogOutputFile: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var title: String
    public var description: String     // includes chapter timestamps for the full vlog
    public var isShort: Bool
}

/// One vlog job, saved as JSON in its own folder (no database migration; proxies/analysis/segments are cached beside it).
public struct VlogProject: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var createdAt = Date()
    public var inputs: [String]
    public var options: VlogOptions
    public var stage: VlogStage = .queued
    public var error: String?
    public var assets: [VlogAsset] = []
    public var chapters: [VlogChapter] = []
    public var plan: VlogPlan?
    public var outputs: [VlogOutputFile] = []
    public var name: String { options.title.isEmpty ? URL(fileURLWithPath: inputs.first ?? "Vlog").lastPathComponent : options.title }
    public var folder: URL { Paths.dir("vlogs", id.uuidString) }
    public var isActive: Bool { ![.done, .failed].contains(stage) }
    public var rejected: [VlogAsset] { assets.filter { $0.rejected != nil } }
}

@MainActor @Observable public final class VlogModel {
    public private(set) var projects: [VlogProject] = []
    public private(set) var progress: Double?
    public private(set) var runningID: UUID?
    let binaries: Binaries?
    let llm: LLMClient
    let transcriber: (any Transcribing)?
    let cost: CostTracker
    let settings: @MainActor () -> AppSettings
    @ObservationIgnored var worker: Task<Void, Never>?

    public init(binaries: Binaries?, llm: LLMClient, transcriber: (any Transcribing)?, cost: CostTracker, settings: @escaping @MainActor () -> AppSettings) {
        self.binaries = binaries; self.llm = llm; self.transcriber = transcriber; self.cost = cost; self.settings = settings
        let root = Paths.dir("vlogs")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        projects = dirs.compactMap { try? JSONDecoder().decode(VlogProject.self, from: Data(contentsOf: $0.appendingPathComponent("project.json"))) }
            .sorted { $0.createdAt > $1.createdAt }
        for i in projects.indices where projects[i].isActive && projects[i].stage != .queued {
            projects[i].stage = .failed; projects[i].error = "Interrupted when ClipForge quit. Press Retry — finished work is reused."
            save(projects[i])
        }
    }

    func save(_ p: VlogProject) {
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p } else { projects.insert(p, at: 0) }
        try? JSONEncoder().encode(p).write(to: p.folder.appendingPathComponent("project.json"), options: .atomic)
    }

    @discardableResult
    public func create(inputs: [URL], options: VlogOptions) throws -> VlogProject {
        guard !FootageImporter.files(inputs).isEmpty else { throw ClipForgeError("No videos or photos found (mp4, mov, m4v, mkv, jpg, png, heic).") }
        let p = VlogProject(inputs: inputs.map(\.path), options: options)
        save(p); pump()
        return p
    }

    /// Retry or re-plan: everything finished is cached, so this only redoes what's missing.
    public func retry(_ id: UUID, replan: Bool = false) {
        guard runningID != id, var p = projects.first(where: { $0.id == id }) else { return }
        if replan { p.plan = nil }
        p.stage = .queued; p.error = nil
        save(p); pump()
    }

    public func update(_ id: UUID, _ change: (inout VlogOptions) -> Void) {
        guard var p = projects.first(where: { $0.id == id }) else { return }
        change(&p.options); save(p)
    }

    public func cancel(_ id: UUID) { if runningID == id { worker?.cancel() } }

    public func delete(_ id: UUID) {
        guard runningID != id, let p = projects.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: p.folder)
        projects.removeAll { $0.id == id }
    }

    func pump() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, let p = self.projects.last(where: { $0.stage == .queued }) {
                self.runningID = p.id
                await self.process(p)
                self.runningID = nil; self.progress = nil
            }
            if let self, Task.isCancelled, let id = self.runningID, var p = self.projects.first(where: { $0.id == id }) {
                p.stage = .failed; p.error = "Cancelled."; self.save(p); self.runningID = nil; self.progress = nil
            }
            self?.worker = nil
            if self?.projects.contains(where: { $0.stage == .queued }) == true { self?.pump() }
        }
    }

    func process(_ start: VlogProject) async {
        var p = start
        guard let ffmpeg = binaries?.ffmpeg else { p.stage = .failed; p.error = Binaries.setupHint; return save(p) }
        let proxyDir = Paths.dir("vlogs", p.id.uuidString, "proxies"), cache = Paths.dir("vlogs", p.id.uuidString, "analysis")
        do {
            // 1. Import: metadata for new files, proxies for videos (both resumable).
            p.stage = .importing; save(p)
            let files = FootageImporter.files(p.inputs.map(URL.init(fileURLWithPath:)))
            var assets: [VlogAsset] = []
            for (i, f) in files.enumerated() {
                try Task.checkCancellation()
                let known = p.assets.first { $0.path == f.path && $0.id == FootageImporter.fingerprint(f) }
                var a = if let known { known } else { try await FootageImporter.metadata(f) }
                if !a.isPhoto { a.proxyPath = try await FootageImporter.proxy(a, dir: proxyDir, ffmpeg: ffmpeg) }
                assets.append(a)
                progress = Double(i + 1) / Double(files.count)
            }
            p.assets = assets.sorted { $0.captured < $1.captured }
            save(p)

            // 2. Shot analysis (cached per file), duplicates, chapters.
            p.stage = .analyzing; progress = 0; save(p)
            if let transcriber, p.assets.contains(where: { $0.hasAudio }) { try await transcriber.load(model: settings().whisperModel) }
            for i in p.assets.indices {
                try Task.checkCancellation()
                p.assets[i] = try await ShotAnalyzer.analyze(p.assets[i], ffmpeg: ffmpeg, transcriber: transcriber, cache: cache)
                progress = Double(i + 1) / Double(p.assets.count)
            }
            ShotAnalyzer.markDuplicates(&p.assets)
            if p.chapters.isEmpty || p.plan == nil {
                p.chapters = ChapterBuilder.group(p.assets)
                await ChapterBuilder.name(&p.chapters, assets: p.assets)
            }
            for c in p.chapters { for id in c.assetIDs { if let i = p.assets.firstIndex(where: { $0.id == id }) { p.assets[i].chapter = c.index } } }
            save(p)

            // 3. Plan (one Claude vision call; validated, one retry).
            if p.plan == nil {
                p.stage = .planning; progress = nil; save(p)
                let (plan, named) = try await VlogPlanner.plan(assets: p.assets, chapters: p.chapters, options: p.options, ffmpeg: ffmpeg,
                                                              work: p.folder, client: llm, cost: cost, settings: settings())
                p.plan = plan; p.chapters = named
                save(p)
            }

            // 4. Render: full vlog (16:9, route intro, chapters) + shorts (9:16). Segments are cached.
            p.stage = .rendering; progress = 0; save(p)
            guard var plan = p.plan else { throw ClipForgeError("No edit plan — press Retry.") }
            var byID = Dictionary(uniqueKeysWithValues: p.assets.map { ($0.id, $0) })
            if var full = plan.full, let route = await RouteIntro.make(p.chapters, assets: p.assets, dir: p.folder) {
                byID[route.id] = route
                if full.beats.first?.asset != route.id {
                    var intro = StoryBeat(purpose: "title", start: 0, end: 3.5, caption: p.options.title.isEmpty ? full.title : p.options.title, importantAudio: false)
                    intro.asset = route.id
                    full.beats.insert(intro, at: 0)
                }
                plan.full = full
            }
            var outs: [VlogOutputFile] = []
            let boards = plan.all
            let music = try await musicTracks(p.options.vibe, ffmpeg: ffmpeg)
            for (k, var sb) in boards.enumerated() {
                let isShort = plan.full == nil || k > 0
                sb.styleID = p.options.vibe.styleID
                let fmt: OutputFormat = isShort ? .vertical : .landscape
                var so = StoryOptions(); so.format = fmt
                let out = p.folder.appendingPathComponent(isShort ? "short-\(k + (plan.full == nil ? 1 : 0)).mp4" : "vlog.mp4")
                let base = Double(k) / Double(boards.count), span = 1 / Double(boards.count)
                try await VlogRenderer.render(sb, assets: byID, chapters: p.chapters, output: .init(format: fmt, vibe: p.options.vibe),
                                              music: isShort ? Array(music.prefix(1)) : music, options: so, ffmpeg: ffmpeg,
                                              work: p.folder, out: out) { f in Task { @MainActor [weak self] in self?.progress = base + f * span } }
                let marks = isShort ? [] : VlogRenderer.chapterMarks(sb, chapters: p.chapters)
                let desc = ([sb.description] + (marks.isEmpty ? [] : ["", "Chapters:"] + marks) + ["", sb.hashtags.joined(separator: " ")]).joined(separator: "\n")
                outs.append(VlogOutputFile(path: out.path, title: sb.title, description: desc, isShort: isShort))
            }
            p.plan = plan; p.outputs = outs
            p.stage = .done; progress = nil
            if p.options.cleanupProxies { try? FileManager.default.removeItem(at: proxyDir); for i in p.assets.indices { p.assets[i].proxyPath = nil } }
            save(p)
        } catch {
            p.stage = .failed
            p.error = error is CancellationError ? "Cancelled." : error.localizedDescription
            save(p)
        }
    }

    /// The vibe's mood first, then neighbours, so a long vlog gets a different track per chapter.
    func musicTracks(_ vibe: VlogVibe, ffmpeg: URL) async throws -> [MusicTrack] {
        var out: [MusicTrack] = []
        for mood in [vibe.mood] + StoryTone.allCases.filter({ $0 != vibe.mood && $0 != .funny }) {
            let t = try await MusicLibrary.pick(mood: mood, ffmpeg: ffmpeg)
            if !out.contains(where: { $0.path == t.path }) { out.append(t) }
            if out.count == 3 { break }
        }
        return out
    }

    /// Writes the full vlog (or a short) and its description to a folder of the user's choice.
    public func export(_ o: VlogOutputFile, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: o.path), to: url)
        try (o.title + "\n\n" + o.description + "\n").write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }
}

/// Map of the trip route (chapter locations in order) as a still image, used as the full vlog's title beat.
enum RouteIntro {
    @MainActor static func make(_ chapters: [VlogChapter], assets: [VlogAsset], dir: URL) async -> VlogAsset? {
        let pts = chapters.compactMap { c in assets.first { c.assetIDs.contains($0.id) && $0.latitude != nil } }
            .map { CLLocationCoordinate2D(latitude: $0.latitude!, longitude: $0.longitude!) }
        guard pts.count >= 2 else { return nil }
        let out = dir.appendingPathComponent("route.png")
        if !FileManager.default.fileExists(atPath: out.path) {
            let o = MKMapSnapshotter.Options()
            let rect = pts.map { MKMapRect(origin: MKMapPoint($0), size: MKMapSize(width: 1, height: 1)) }.reduce(MKMapRect.null) { $0.union($1) }
            o.mapRect = rect.insetBy(dx: -max(rect.width, 20_000) * 0.35, dy: -max(rect.height, 20_000) * 0.35)
            o.size = CGSize(width: 1920, height: 1080)
            o.pointOfInterestFilter = .excludingAll
            guard let snap = try? await MKMapSnapshotter(options: o).start() else { return nil }
            let img = NSImage(size: o.size)
            img.lockFocus()
            snap.image.draw(in: CGRect(origin: .zero, size: o.size))
            let path = NSBezierPath()
            for (i, c) in pts.enumerated() {
                let p = snap.point(for: c)   // macOS: already bottom-left image coordinates
                i == 0 ? path.move(to: p) : path.line(to: p)
            }
            NSColor.white.setStroke(); path.lineWidth = 10; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
            NSColor.systemRed.setStroke(); path.lineWidth = 6; path.stroke()
            for c in pts {
                let p = snap.point(for: c)   // macOS: already bottom-left image coordinates
                NSColor.white.setFill(); NSBezierPath(ovalIn: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)).fill()
                NSColor.systemRed.setFill(); NSBezierPath(ovalIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)).fill()
            }
            img.unlockFocus()
            guard let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            try? png.write(to: out)
        }
        return VlogAsset(id: "route", path: out.path, isPhoto: true, captured: chapters.first?.start ?? .now, duration: 0, width: 1920, height: 1080,
                         hasAudio: false, analyzed: true, brightness: 0.5, score: 50)
    }
}
