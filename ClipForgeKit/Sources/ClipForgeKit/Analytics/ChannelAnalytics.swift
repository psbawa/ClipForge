import Foundation

/// Read-only: YouTube Data API (videos list) + YouTube Analytics API (metrics). Never writes anything to YouTube.
extension ChannelAnalytics {
    static let rangeDays = 90
    static let maxVideos = 200

    static func get(_ url: String, _ query: [String: String], auth: AccessTokenProviding, session: URLSession) async throws -> [String: Any] {
        var c = URLComponents(string: url)!
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(try await auth.accessToken(forceRefresh: false))", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = ((o["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            if msg.contains("has not been used") || msg.contains("is disabled") {
                throw ClipForgeError("Enable the “YouTube Analytics API” for your Google Cloud project, then try again. (\(msg))")
            }
            throw ClipForgeError("YouTube stats request failed: \(msg)")
        }
        return o
    }

    /// Analytics "rows" → [[header: value]].
    static func rows(_ o: [String: Any]) -> [[String: Any]] {
        let headers = (o["columnHeaders"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return (o["rows"] as? [[Any]] ?? []).map { Dictionary(uniqueKeysWithValues: zip(headers, $0)) }
    }
    static func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? Double(v as? String ?? "") ?? 0 }

    public static func pull(auth: AccessTokenProviding, session: URLSession = .shared) async throws -> ChannelSnapshot {
        var s = ChannelSnapshot()
        let ch = try await get("https://www.googleapis.com/youtube/v3/channels", ["part": "snippet,statistics,contentDetails", "mine": "true"], auth: auth, session: session)
        guard let c = (ch["items"] as? [[String: Any]])?.first else { throw ClipForgeError("No YouTube channel on this Google account.") }
        s.channelTitle = (c["snippet"] as? [String: Any])?["title"] as? String ?? ""
        let st = c["statistics"] as? [String: Any] ?? [:]
        s.subscribers = Int(num(st["subscriberCount"])); s.totalViews = Int(num(st["viewCount"])); s.videoCount = Int(num(st["videoCount"]))
        let uploads = ((c["contentDetails"] as? [String: Any])?["relatedPlaylists"] as? [String: Any])?["uploads"] as? String ?? ""

        // Uploads playlist → ids (newest first), then details in batches of 50.
        var ids: [String] = [], page: String?
        repeat {
            var q = ["part": "contentDetails", "playlistId": uploads, "maxResults": "50"]
            if let page { q["pageToken"] = page }
            let o = try await get("https://www.googleapis.com/youtube/v3/playlistItems", q, auth: auth, session: session)
            ids += (o["items"] as? [[String: Any]] ?? []).compactMap { ($0["contentDetails"] as? [String: Any])?["videoId"] as? String }
            page = o["nextPageToken"] as? String
        } while page != nil && ids.count < maxVideos
        var videos: [String: VideoStats] = [:]
        let iso = ISO8601DateFormatter()
        for batch in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            let o = try await get("https://www.googleapis.com/youtube/v3/videos", ["part": "snippet,contentDetails,statistics", "id": batch.joined(separator: ",")], auth: auth, session: session)
            for v in o["items"] as? [[String: Any]] ?? [] {
                guard let id = v["id"] as? String else { continue }
                let sn = v["snippet"] as? [String: Any] ?? [:], stv = v["statistics"] as? [String: Any] ?? [:]
                var x = VideoStats(id: id, title: sn["title"] as? String ?? "", published: iso.date(from: sn["publishedAt"] as? String ?? "") ?? .distantPast,
                                   seconds: TrendRefresh.seconds((v["contentDetails"] as? [String: Any])?["duration"] as? String ?? "") ?? 0)
                x.views = Int(num(stv["viewCount"])); x.likes = Int(num(stv["likeCount"])); x.comments = Int(num(stv["commentCount"]))
                videos[id] = x
            }
        }
        // Lifetime per-video analytics (watch time, retention summary, subs gained).
        let end = day(.now)
        let pv = try await get("https://youtubeanalytics.googleapis.com/v2/reports", [
            "ids": "channel==MINE", "startDate": "2005-02-14", "endDate": end, "dimensions": "video", "sort": "-views", "maxResults": "200",
            "metrics": "views,estimatedMinutesWatched,averageViewDuration,averageViewPercentage,likes,comments,subscribersGained",
        ], auth: auth, session: session)
        for r in rows(pv) {
            guard let id = r["video"] as? String, var x = videos[id] else { continue }
            x.views = max(x.views, Int(num(r["views"]))); x.minutesWatched = num(r["estimatedMinutesWatched"])
            x.avgViewSeconds = num(r["averageViewDuration"]); x.avgViewPercent = num(r["averageViewPercentage"])
            x.subscribersGained = Int(num(r["subscribersGained"]))
            videos[id] = x
        }
        s.videos = ids.compactMap { videos[$0] }
        // Daily channel trend.
        let start = day(Calendar.current.date(byAdding: .day, value: -rangeDays, to: .now)!)
        let daily = try await get("https://youtubeanalytics.googleapis.com/v2/reports", [
            "ids": "channel==MINE", "startDate": start, "endDate": end, "dimensions": "day", "sort": "day",
            "metrics": "views,estimatedMinutesWatched,subscribersGained",
        ], auth: auth, session: session)
        s.days = rows(daily).map { DayStats(day: $0["day"] as? String ?? "", views: Int(num($0["views"])), minutes: num($0["estimatedMinutesWatched"]),
                                            subscribers: Int(num($0["subscribersGained"]))) }
        return s
    }

    /// Audience retention curve for one video (share of viewers still watching at each point).
    public static func retention(_ videoID: String, auth: AccessTokenProviding, session: URLSession = .shared) async throws -> [RetentionPoint] {
        let o = try await get("https://youtubeanalytics.googleapis.com/v2/reports", [
            "ids": "channel==MINE", "startDate": "2005-02-14", "endDate": day(.now), "dimensions": "elapsedVideoTimeRatio",
            "metrics": "audienceWatchRatio,relativeRetentionPerformance", "filters": "video==\(videoID)",
        ], auth: auth, session: session)
        return rows(o).map { RetentionPoint(ratio: num($0["elapsedVideoTimeRatio"]), watch: num($0["audienceWatchRatio"]), relative: num($0["relativeRetentionPerformance"])) }
    }

    static func folder() -> URL { let u = Paths.support.appendingPathComponent("analytics"); try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }
    public static func save(_ s: ChannelSnapshot) { try? JSONEncoder().encode(s).write(to: folder().appendingPathComponent(day(s.takenAt) + ".json"), options: .atomic) }
    public static func latest() -> ChannelSnapshot? {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder(), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        return files.last.flatMap { try? JSONDecoder().decode(ChannelSnapshot.self, from: Data(contentsOf: $0)) }
    }

    // MARK: What works on my channel

    static let patternsModel = "claude-sonnet-5-5"
    static let patternsSystem = """
    You analyze a YouTube creator's own videos to find what works ON THIS CHANNEL. You get the best and worst performers
    (title, Short or long, length, views, average % viewed, subscribers gained). Write 5-8 short, concrete, evidence-based patterns
    (e.g. "Titles naming the exact play ('1v4 clutch') beat vague hype titles: 3 of the top 5 vs 0 of the bottom 5").
    Cite the numbers. No generic YouTube advice; if the data is too thin for a claim, say so.
    Output ONLY a JSON array of strings.
    """

    public static func patterns(_ s: ChannelSnapshot, client: LLMClient, cost: CostTracker, settings: AppSettings) async throws -> [String] {
        let ranked = s.videos.filter { $0.published < Date().addingTimeInterval(-3 * 86400) }.sorted { $0.views > $1.views }
        guard ranked.count >= 4 else { throw ClipForgeError("Need at least 4 videos older than 3 days to find patterns.") }
        func line(_ v: VideoStats) -> String {
            "\"\(v.title)\" · \(v.isShort ? "Short" : "long") \(Int(v.seconds)) s · \(v.views) views · \(String(format: "%.0f", v.avgViewPercent))% viewed · +\(v.subscribersGained) subs"
        }
        let n = min(10, ranked.count / 2)
        let text = "Top performers:\n" + ranked.prefix(n).map(line).joined(separator: "\n") + "\n\nBottom performers:\n" + ranked.suffix(n).map(line).joined(separator: "\n")
        guard await cost.canSpend(budget: settings.dailyBudgetUSD) else { throw HighlightError.budgetReached }
        let r = try await client.complete(model: patternsModel, system: patternsSystem, content: [.text(text)], maxTokens: 1500, effort: "medium")
        await cost.record(r.usage, price: settings.prices[patternsModel])
        guard let a = r.text.firstIndex(of: "["), let b = r.text.lastIndex(of: "]"),
              let list = try? JSONDecoder().decode([String].self, from: Data(r.text[a...b].utf8)), !list.isEmpty else {
            throw ClipForgeError("Couldn't read Claude's channel patterns. Try again.")
        }
        return list
    }
}
