import Foundation
import Testing
@testable import ClipForgeKit

/// Scripted HTTP: each request pops the next (status, headers, body); every request is recorded.
final class MockHTTP: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var script: [(Int, [String: String], String)] = []
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, headers, body) = Self.lock.withLock {
            Self.seen.append(request)
            return Self.script.isEmpty ? (500, [:], "{}") : Self.script.removeFirst()
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session(_ s: [(Int, [String: String], String)]) -> URLSession {
        lock.withLock { script = s; seen = [] }
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockHTTP.self]
        return URLSession(configuration: c)
    }
}

final class FakeAuth: AccessTokenProviding, @unchecked Sendable {
    var refreshes = 0
    func accessToken(forceRefresh: Bool) async throws -> String {
        if forceRefresh { refreshes += 1 }
        return "tok\(refreshes)"
    }
}

let videoJSON = #"{"id":"abc123","status":{"privacyStatus":"private"},"snippet":{"channelId":"UC_me"}}"#

func tempClip() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
    try Data(repeating: 7, count: 1000).write(to: u)
    return u
}

// MockHTTP uses shared static state, so these run one at a time.
@Suite(.serialized) struct PublishTests {
    @Test func startSessionSendsShortsMetadata() async throws {
        let svc = PublishService(auth: FakeAuth(), session: MockHTTP.session([(200, ["Location": "https://up/session1"], "")]), sleep: { _ in })
        let req = UploadRequest(file: try tempClip(), title: "Big moment", description: "Wow", tags: ["a"], privacy: "private")
        let url = try await svc.startSession(req)
        #expect(url.absoluteString == "https://up/session1")
        let r = MockHTTP.seen[0]
        #expect(r.value(forHTTPHeaderField: "X-Upload-Content-Length") == "1000")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok0")
        let meta = PublishService.metadata(req)
        let snippet = meta["snippet"] as! [String: Any]
        #expect(snippet["title"] as? String == "Big moment #Shorts")
        #expect((snippet["description"] as? String)?.hasSuffix("#Shorts") == true)
    }

    @Test func uploadRetriesServerErrorsThenSucceeds() async throws {
        let svc = PublishService(auth: FakeAuth(), session: MockHTTP.session([
            (308, [:], ""),          // status query: nothing uploaded yet
            (503, [:], "{}"),        // PUT fails
            (200, [:], videoJSON),   // retry succeeds
        ]), sleep: { _ in })
        let r = try await svc.upload(UploadRequest(file: try tempClip(), title: "t", description: "", tags: [], privacy: "public"), session: URL(string: "https://up/s")!)
        #expect(r == UploadResult(videoID: "abc123", privacy: "private", channelID: "UC_me"))
        #expect(MockHTTP.seen.count == 3)
    }

    @Test func completedSessionIsNeverReuploaded() async throws {
        let svc = PublishService(auth: FakeAuth(), session: MockHTTP.session([(200, [:], videoJSON)]), sleep: { _ in })
        let r = try await svc.upload(UploadRequest(file: try tempClip(), title: "t", description: "", tags: [], privacy: "private"), session: URL(string: "https://up/s")!)
        #expect(r.videoID == "abc123")
        #expect(MockHTTP.seen.count == 1)
        #expect(MockHTTP.seen[0].value(forHTTPHeaderField: "Content-Range") == "bytes */1000")
    }

    @Test func partialSessionResumesFromOffset() async throws {
        let svc = PublishService(auth: FakeAuth(), session: MockHTTP.session([(308, ["Range": "bytes=0-399"], ""), (200, [:], videoJSON)]), sleep: { _ in })
        _ = try await svc.upload(UploadRequest(file: try tempClip(), title: "t", description: "", tags: [], privacy: "private"), session: URL(string: "https://up/s")!)
        #expect(MockHTTP.seen[1].value(forHTTPHeaderField: "Content-Range") == "bytes 400-999/1000")
    }

    @Test func quotaErrorIsNotRetried() async throws {
        let quota = #"{"error":{"code":403,"message":"quota","errors":[{"reason":"quotaExceeded"}]}}"#
        let svc = PublishService(auth: FakeAuth(), session: MockHTTP.session([(403, [:], quota)]), sleep: { _ in })
        await #expect(throws: PublishError.quota) {
            try await svc.startSession(UploadRequest(file: try tempClip(), title: "t", description: "", tags: [], privacy: "private"))
        }
        #expect(MockHTTP.seen.count == 1)
    }

    @Test func rateLimitBacksOffAnd401Refreshes() async throws {
        let rate = #"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}"#
        let auth = FakeAuth()
        let svc = PublishService(auth: auth, session: MockHTTP.session([
            (403, [:], rate), (401, [:], "{}"), (200, [:], #"{"items":[{"id":"UC_me","snippet":{"title":"Me"}}]}"#),
        ]), sleep: { _ in })
        let c = try await svc.channel()
        #expect(c == Channel(id: "UC_me", title: "Me"))
        #expect(auth.refreshes == 1)
        #expect(MockHTTP.seen.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tok1")
    }
}
