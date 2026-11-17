import Foundation

/// Weekly trend refresh from the only official source that allows it: YouTube Data API `videos.list?chart=mostPopular`
/// (1 quota unit per call, read-only scope). Claude turns the metadata into new dated profile versions; history is kept.
/// TikTok / Instagram expose no trending-video or trending-sound API for this, and nothing is scraped.
enum TrendRefresh {
    struct Niche: Sendable { var name: String; var categoryID: String; var profileIDs: [String] }
    static let niches = [
        Niche(name: "gaming", categoryID: "20", profileIDs: ["gaming-fast", "tiktok-meme", "countdown", "before-after"]),
        Niche(name: "travel", categoryID: "19", profileIDs: ["travel-cinematic", "reels-lifestyle"]),
        Niche(name: "people & blogs", categoryID: "22", profileIDs: ["aesthetic-vlog", "podcast-bold", "pov-storytime", "longform-talking"]),
    ]
    static let regions = ["US", "IN", "GB"]
    static let lastRunKey = "trends.lastRefresh"
    static let model = "claude-sonnet-5-5"

    struct Video: Sendable { var title: String; var seconds: Double; var views: Int; var tags: [String] }

    /// ISO 8601 duration ("PT1M5S") → seconds.
    static func seconds(_ iso: String) -> Double {
        var total = 0.0, num = ""
        for ch in iso.dropFirst(2) {
            if ch.isNumber || ch == "." { num.append(ch); continue }
            let v = Double(num) ?? 0; num = ""
            switch ch { case "H": total += v * 3600; case "M": total += v * 60; case "S": total += v; default: break }
        }
        return total
    }

    static func fetch(_ niche: Niche, region: String, auth: AccessTokenProviding, session: URLSession) async throws -> [Video] {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/videos?part=snippet,contentDetails,statistics&chart=mostPopular&videoCategoryId=\(niche.categoryID)&regionCode=\(region)&maxResults=50")!)
        req.setValue("Bearer \(try await auth.accessToken(forceRefresh: false))", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 || code == 400 { return [] }   // category not available in this region
        guard code == 200 else { throw PublishService.error(code, data) }
        let items = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        return items.map { i in
            let sn = i["snippet"] as? [String: Any] ?? [:], cd = i["contentDetails"] as? [String: Any] ?? [:], st = i["statistics"] as? [String: Any] ?? [:]
            return Video(title: sn["title"] as? String ?? "", seconds: seconds(cd["duration"] as? String ?? "PT0S"),
                         views: Int(st["viewCount"] as? String ?? "0") ?? 0, tags: (sn["tags"] as? [String] ?? []).prefix(8).map { $0 })
        }
    }

    /// Short text digest of what's popular, for the model.
    static func digest(_ videos: [Video]) -> String {
        let shorts = videos.filter { $0.seconds <= 60 }, long = videos.filter { $0.seconds > 60 }
        let med = videos.map(\.seconds).sorted().dropFirst(videos.count / 2).first ?? 0
        let tags = Dictionary(grouping: videos.flatMap(\.tags).map { $0.lowercased() }, by: { $0 }).mapValues(\.count)
            .sorted { $0.value > $1.value }.prefix(15).map(\.key)
        let titles = videos.sorted { $0.views > $1.views }.prefix(25).map { "- \($0.title) (\(Int($0.seconds)) s, \($0.views) views)" }
        return "\(videos.count) most-popular videos: \(shorts.count) Shorts-length, \(long.count) longer; median length \(Int(med)) s.\nTop tags: \(tags.joined(separator: ", "))\nTop titles:\n\(titles.joined(separator: "\n"))"
    }

    /// Fetch + summarize + save new versions. Returns the new profiles.
    static func run(auth: AccessTokenProviding, client: LLMClient, cost: CostTracker, settings: AppSettings,
                    session: URLSession = .shared) async throws -> [StyleProfile] {
        var saved: [StyleProfile] = []
        for niche in niches {
            var videos: [Video] = []
            for r in regions { videos += (try? await fetch(niche, region: r, auth: auth, session: session)) ?? [] }
            guard !videos.isEmpty else { continue }
            let current = niche.profileIDs.compactMap(StyleLibrary.profile)
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            let user = """
            Niche: \(niche.name). Data from YouTube's official most-popular charts (\(regions.joined(separator: ", "))), fetched \(Date().formatted(date: .abbreviated, time: .omitted)):
            \(digest(videos))

            Current profiles (JSON array):
            \(String(decoding: try enc.encode(current), as: UTF8.self))
            """
            guard await cost.canSpend(budget: settings.dailyBudgetUSD) else { throw HighlightError.budgetReached }
            let r = try await client.complete(model: model, system: system, user: user, maxTokens: 8000, effort: "medium")
            await cost.record(r.usage, price: settings.prices[model])
            guard let a = r.text.firstIndex(of: "["), let b = r.text.lastIndex(of: "]"),
                  let list = (try? JSONSerialization.jsonObject(with: Data(r.text[a...b].utf8))) as? [[String: Any]] else {
                throw ClipForgeError("Trend refresh for \(niche.name): Claude's answer wasn't valid profile JSON.")
            }
            // Each answer is laid over the current version, so partial or slightly off answers can't corrupt a profile.
            let updated = list.compactMap { item -> StyleProfile? in
                guard let id = item["id"] as? String, let base = current.first(where: { $0.id == id }) else { return nil }
                return StyleLibrary.merge(base, patch: item)
            }
            for var p in updated where niche.profileIDs.contains(p.id) {
                // Only keep a new version when the recipe itself changed (notes/version/origin don't count).
                guard let old = current.first(where: { $0.id == p.id }), changed(old, p) else { continue }
                p.version = StyleLibrary.today
                p.origin = "trend-refresh"
                try StyleLibrary.save(p)
                saved.append(p)
            }
        }
        UserDefaults.standard.set(Date(), forKey: lastRunKey)
        return saved
    }

    static func changed(_ a: StyleProfile, _ b: StyleProfile) -> Bool {
        var x = a, y = b
        (x.version, x.notes, x.origin) = ("", "", "")
        (y.version, y.notes, y.origin) = ("", "", "")
        return x != y
    }

    static let system = """
    You maintain editing "trend profiles" for a video editor. Given what's currently most popular in a niche on YouTube (titles, lengths,
    tags, views) and the current profiles, update each profile where the evidence supports it: hook style, structure, ideal length,
    pacing, caption tone, music energy. Change only what the data supports; keep everything else. Put a short evidence summary
    (what in the data motivated each change) in "notes". Keep the same ids and the exact JSON schema.
    Output ONLY a JSON array of the updated profiles.
    """
}
