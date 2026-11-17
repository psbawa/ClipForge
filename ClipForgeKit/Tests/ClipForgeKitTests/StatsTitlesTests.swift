import Foundation
import SwiftData
import Testing
@testable import ClipForgeKit

@Test func channelStatsSignInIsReadOnly() {
    let scopes = YouTubeAuth.analyticsScopes.split(separator: " ").map(String.init)
    #expect(Set(scopes) == ["https://www.googleapis.com/auth/youtube.readonly", "https://www.googleapis.com/auth/yt-analytics.readonly"])
    #expect(Keychain.Key.googleAnalyticsRefreshToken != Keychain.Key.googleRefreshToken)   // separate token
}

@Test func shortsSplitAndBestSlots() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let iso = ISO8601DateFormatter()
    func v(_ id: String, _ secs: Double, _ views: Int, _ pct: Double, _ t: String) -> VideoStats {
        var x = VideoStats(id: id, title: id, published: iso.date(from: t)!, seconds: secs); x.views = views; x.avgViewPercent = pct; return x
    }
    let vids = [v("a", 30, 1000, 80, "2026-11-02T18:00:00Z"), v("b", 45, 3000, 90, "2026-11-09T19:30:00Z"),   // Mondays 16–20
                v("c", 600, 200, 40, "2026-11-04T09:00:00Z"), v("d", 900, 400, 30, "2026-11-11T10:00:00Z"),   // Wednesdays 08–12
                v("e", 50, 10, 20, "2026-11-06T02:00:00Z")]                                                     // lone slot: ignored
    let s = ChannelAnalytics.split(vids)
    #expect(s.shorts.count == 3 && s.shorts.medianViews == 1000 && s.long.count == 2 && s.long.medianViews == 400)
    let slots = ChannelAnalytics.bestSlots(vids, calendar: cal)
    #expect(slots.map(\.label) == ["Mon 16:00–20:00", "Wed 08:00–12:00"])
    #expect(slots[0].medianViews == 3000 && slots[0].count == 2)
}

extension PublishTests {
    @Test func statsPullUsesOnlyReadOnlyGets() async throws {
        let channel = #"{"items":[{"snippet":{"title":"Demo Channel"},"statistics":{"subscriberCount":"1200","viewCount":"50000","videoCount":"2"},"contentDetails":{"relatedPlaylists":{"uploads":"UU1"}}}]}"#
        let playlist = #"{"items":[{"contentDetails":{"videoId":"v1"}},{"contentDetails":{"videoId":"v2"}}]}"#
        let videos = #"{"items":[{"id":"v1","snippet":{"title":"Clutch 1v3","publishedAt":"2026-11-01T18:00:00Z"},"contentDetails":{"duration":"PT42S"},"statistics":{"viewCount":"9000","likeCount":"400","commentCount":"12"}},{"id":"v2","snippet":{"title":"Full stream","publishedAt":"2026-10-01T18:00:00Z"},"contentDetails":{"duration":"PT2H1M"},"statistics":{"viewCount":"300"}}]}"#
        let perVideo = #"{"columnHeaders":[{"name":"video"},{"name":"views"},{"name":"estimatedMinutesWatched"},{"name":"averageViewDuration"},{"name":"averageViewPercentage"},{"name":"likes"},{"name":"comments"},{"name":"subscribersGained"}],"rows":[["v1",9100,4000,31,74.5,400,12,55],["v2",310,900,700,9.6,3,0,1]]}"#
        let daily = #"{"columnHeaders":[{"name":"day"},{"name":"views"},{"name":"estimatedMinutesWatched"},{"name":"subscribersGained"}],"rows":[["2026-11-15",120,60,2],["2026-11-16",340,150,5]]}"#
        let session = MockHTTP.session([(200, [:], channel), (200, [:], playlist), (200, [:], videos), (200, [:], perVideo), (200, [:], daily)])
        let s = try await ChannelAnalytics.pull(auth: FakeAuth(), session: session)
        #expect(s.channelTitle == "Demo Channel" && s.subscribers == 1200 && s.videos.count == 2)
        let v1 = try #require(s.videos.first { $0.id == "v1" })
        #expect(v1.isShort && v1.views == 9100 && v1.avgViewPercent == 74.5 && v1.subscribersGained == 55)
        #expect(s.videos.first { $0.id == "v2" }?.isShort == false)
        #expect(s.days.map(\.views) == [120, 340])
        #expect(MockHTTP.seen.allSatisfy { ($0.httpMethod ?? "GET") == "GET" })                           // never writes
        #expect(MockHTTP.seen.contains { $0.url!.absoluteString.contains("youtubeanalytics.googleapis.com/v2/reports") && $0.url!.absoluteString.contains("ids=channel%3D%3DMINE") })
    }

    @Test func statsMissingAnalyticsApiExplainsTheFix() async throws {
        let err = #"{"error":{"message":"YouTube Analytics API has not been used in project 123 before or it is disabled."}}"#
        let channel = #"{"items":[{"snippet":{"title":"x"},"statistics":{},"contentDetails":{"relatedPlaylists":{"uploads":"UU1"}}}]}"#
        let session = MockHTTP.session([(200, [:], channel), (200, [:], #"{"items":[]}"#), (403, [:], err)])
        await #expect(throws: (any Error).self) { _ = try await ChannelAnalytics.pull(auth: FakeAuth(), session: session) }
        do { _ = try await ChannelAnalytics.pull(auth: FakeAuth(), session: MockHTTP.session([(200, [:], channel), (200, [:], #"{"items":[]}"#), (403, [:], err)])) }
        catch { #expect(error.localizedDescription.contains("Enable the “YouTube Analytics API”")) }
    }
}

final class TitleLLM: LLMClient, @unchecked Sendable {
    var replies: [String]; var systems: [String] = []
    init(_ r: [String]) { replies = r }
    func complete(model: String, system: String, content: [LLMContent], maxTokens: Int, effort: String) async throws -> LLMResponse {
        systems.append(system)
        return LLMResponse(text: replies.removeFirst(), usage: LLMUsage(input: 500, output: 100))
    }
}

@Test func titleFactCheckIsEnforced() async throws {
    let opts = #"[{"title":"How did this 1v5 even happen?","hook":"curiosity","recommended":true},{"title":"3 kills in 6 seconds","hook":"number"},{"title":"Can you hit this shot?","hook":"challenge"},{"title":"The moment the squad went quiet","hook":"emotion"},{"title":"POV: last bullet, last enemy","hook":"pov"}]"#
    // Evidence shows 3 kills: the 1v5 claim is rejected (and so loses "recommended"); option 5 is left unchecked.
    let verdicts = #"[{"index":1,"supported":false,"problem":"Evidence shows 3 kills, not a 1v5."},{"index":2,"supported":true},{"index":3,"supported":true},{"index":4,"supported":false,"problem":"No squad reaction is audible."}]"#
    let llm = TitleLLM([opts, verdicts])
    let out = try await TitleWriter.options(title: "t", reason: "Triple kill\nDetected: 12:01 ELIMINATED ×3", said: "", frames: [], patterns: ["Exact numbers win"],
                                            client: llm, cost: freshTracker(), settings: AppSettings())
    #expect(out.count == 5)
    #expect(out.map(\.supported) == [false, true, true, false, false])
    #expect(out[0].problem == "Evidence shows 3 kills, not a 1v5." && out[4].problem == "Not checked.")
    #expect(out.filter(\.recommended).map(\.title) == ["3 kills in 6 seconds"])
    #expect(llm.systems[1].contains("strict fact checker"))
    // A check that doesn't answer clearly approves nothing.
    await #expect(throws: (any Error).self) {
        _ = try await TitleWriter.options(title: "t", reason: "", said: "", frames: [], patterns: [], client: TitleLLM([opts, "ok!"]), cost: freshTracker(), settings: AppSettings())
    }
}

@MainActor @Test func uploadFromMacNeedsRightsAndIsLogged() async throws {
    let (model, pub, _) = try makeModel(channel: "UC_me")
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("mine-\(UUID()).mp4")
    try Data("x".utf8).write(to: file)
    await #expect(throws: (any Error).self) {
        _ = try await model.uploadLocalFile(file, title: "My clip", description: "", tags: [], privacy: "private", rightsConfirmed: false)
    }
    let before = await pub.uploads
    #expect(before.isEmpty)
    let id = try await model.uploadLocalFile(file, title: "My clip", description: "d", tags: ["a"], privacy: "unlisted", rightsConfirmed: true)
    let after = await pub.uploads
    #expect(id == "v1" && after == ["My clip"])
    let log = try #require(try model.context.fetch(FetchDescriptor<PublishLogEntry>()).first { $0.videoID == "v1" })
    #expect(log.result == "published" && log.returnedPrivacy == "unlisted" && log.rightsBasis.contains("confirmed") && log.sourceTitle.hasPrefix("Mac file:"))
}
