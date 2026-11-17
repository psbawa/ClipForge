import Foundation

extension AppModel {
    public func loadStatsState() async { statsSignedIn = await statsAuth.isSignedIn }

    public func signInStats() async {
        do { try await statsAuth.signIn(); statsSignedIn = true; await refreshStats() }
        catch { notify("Channel Stats sign-in failed: \(error.localizedDescription)") }
    }

    public func signOutStats() async { await statsAuth.signOut(); statsSignedIn = false }

    public func refreshStats() async {
        guard !statsBusy else { return }
        statsBusy = true
        defer { statsBusy = false }
        do {
            var s = try await ChannelAnalytics.pull(auth: statsAuth, session: statsSession)
            // Keep the last "what works" patterns until they're re-run.
            if let old = channelStats { s.patterns = old.patterns; s.patternsAt = old.patternsAt }
            ChannelAnalytics.save(s)
            channelStats = s
        } catch { notify(error.localizedDescription) }
    }

    public func findPatterns() async {
        guard var s = channelStats, !statsBusy else { return }
        statsBusy = true
        defer { statsBusy = false }
        do {
            s.patterns = try await ChannelAnalytics.patterns(s, client: llm, cost: cost, settings: settings)
            s.patternsAt = .now
            ChannelAnalytics.save(s)
            channelStats = s
            await refreshCost()
        } catch { notify("Finding patterns failed: \(error.localizedDescription)") }
    }

    public func retention(_ videoID: String) async -> [RetentionPoint] {
        do { return try await ChannelAnalytics.retention(videoID, auth: statsAuth, session: statsSession) }
        catch { notify(error.localizedDescription); return [] }
    }

    /// Five hook titles for a clip, fact-checked against its transcript, detected events and frames.
    public func suggestTitles(_ rec: ClipRecord) async {
        do {
            let said = transcript(for: rec).slice(rec.start, rec.end).joinedText
            rec.titleOptions = try await TitleWriter.options(title: rec.title, reason: rec.reason, said: said, frames: await frames(of: rec),
                                                             patterns: channelStats?.patterns ?? [], client: llm, cost: cost, settings: settings)
            try? context.save()
            await refreshCost()
        } catch { notify("Title suggestions failed: \(error.localizedDescription)") }
    }

    public func useTitle(_ rec: ClipRecord, _ o: TitleOption) {
        guard o.supported else { return }
        rec.title = HighlightLogic.shortsTitle(o.title)
        try? context.save()
    }
}
