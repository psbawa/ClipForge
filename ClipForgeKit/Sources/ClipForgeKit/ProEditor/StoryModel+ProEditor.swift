import Foundation

extension StoryModel {
    /// "Edit like this": analyze a local reference video and save it as a custom style profile.
    public func analyzeReference(_ video: URL, name: String) async throws -> StyleProfile {
        guard let ffmpeg = binaries?.ffmpeg else { throw ClipForgeError(Binaries.setupHint) }
        let work = Paths.dir("references", UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: work) }
        let m = try await withTimeout(seconds: 900) { try await ReferenceAnalyzer.analyze(video, ffmpeg: ffmpeg, work: work) }
        var p = try await ReferenceAnalyzer.profile(m, name: name, client: llm, cost: cost, settings: settings())
        p.notes = "Measured: \(m.cuts) cuts (avg shot \(String(format: "%.1f", m.avgShotSeconds)) s), text on \(Int(m.captionFrameShare * 100))% of frames (\(m.captionPosition)), \(String(format: "%.1f", m.punchInsPer10s)) punch-ins/10 s, \(m.bpm.map { "\(Int($0)) BPM" } ?? "no clear beat").\n" + p.notes
        try StyleLibrary.save(p)
        return p
    }
}

extension AppModel {
    public var lastTrendRefresh: Date? { UserDefaults.standard.object(forKey: TrendRefresh.lastRunKey) as? Date }

    /// Weekly refresh (when enabled and YouTube is connected), or forced from Settings.
    public func refreshTrends(force: Bool = false) async -> String {
        guard force || (settings.trendRefreshEnabled && (lastTrendRefresh.map { Date().timeIntervalSince($0) > 7 * 86400 } ?? true)) else { return "Up to date." }
        guard await auth.isSignedIn else { return "Connect YouTube in Settings → Accounts to refresh trends (read-only data)." }
        do {
            let new = try await withTimeout(seconds: 600) { [auth, llm, cost, settings] in
                try await TrendRefresh.run(auth: auth, client: llm, cost: cost, settings: settings)
            }
            await refreshCost()
            return "Saved \(new.count) updated profile version\(new.count == 1 ? "" : "s"): \(new.map(\.name).joined(separator: ", "))."
        } catch {
            Log.ai.error("Trend refresh failed: \(error.localizedDescription, privacy: .public)")
            return "Trend refresh failed: \(error.localizedDescription)"
        }
    }

    /// Switch a clip's style and re-render (highlight clips) or re-plan (remixes).
    public func applyStyle(_ rec: ClipRecord, styleID: String?, intensity: Double) async {
        if let job = story?.job(rec.storyJobID) {
            var o = job.options; o.styleID = styleID; o.intensity = intensity; job.options = o
            story?.rewrite(job)
            return
        }
        rec.styleID = styleID
        settings.clipIntensity = intensity
        save()
        await rerender(rec, start: rec.start, end: rec.end, style: rec.captionStyle)
    }
}
