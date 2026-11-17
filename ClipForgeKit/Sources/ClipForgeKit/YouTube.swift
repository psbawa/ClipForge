import AppKit
import CryptoKit
import Foundation
import Network

public struct Channel: Sendable, Equatable, Codable { public var id: String; public var title: String }

public protocol AccessTokenProviding: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

// MARK: - OAuth 2.0 for installed apps (PKCE + loopback redirect)

public actor YouTubeAuth: AccessTokenProviding {
    static let scopes = "https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.readonly"
    /// Channel Stats sign-in: read-only, its own refresh token — never touches the publishing token.
    static let analyticsScopes = "https://www.googleapis.com/auth/youtube.readonly https://www.googleapis.com/auth/yt-analytics.readonly"
    let scopes: String
    let tokenKey: String
    var token: (value: String, expires: Date)?

    public init() { scopes = Self.scopes; tokenKey = Keychain.Key.googleRefreshToken }
    public static func analytics() -> YouTubeAuth { YouTubeAuth(scopes: analyticsScopes, tokenKey: Keychain.Key.googleAnalyticsRefreshToken) }
    init(scopes: String, tokenKey: String) { self.scopes = scopes; self.tokenKey = tokenKey }

    public var isSignedIn: Bool { Keychain.get(tokenKey) != nil }

    func client() throws -> (id: String, secret: String) {
        guard let id = Keychain.get(Keychain.Key.googleClientID), !id.isEmpty else {
            throw ClipForgeError("Add your Google OAuth client ID in Settings → Accounts.")
        }
        return (id, Keychain.get(Keychain.Key.googleClientSecret) ?? "")
    }

    public func signIn() async throws {
        let c = try client()
        let verifier = Self.randomURLSafe(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(16)
        let server = try LoopbackServer()
        let redirect = "http://127.0.0.1:\(try await server.start())"
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [.init(name: "client_id", value: c.id), .init(name: "redirect_uri", value: redirect),
                            .init(name: "response_type", value: "code"), .init(name: "scope", value: scopes),
                            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
                            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
                            .init(name: "state", value: state)]
        await MainActor.run { _ = NSWorkspace.shared.open(comps.url!) }
        let query = try await server.waitForRedirect(timeout: 300)
        guard query["state"] == state else { throw ClipForgeError("Sign-in failed: state mismatch.") }
        guard let code = query["code"] else { throw ClipForgeError("Sign-in was cancelled (\(query["error"] ?? "no code")).") }
        let r = try await tokenRequest(["code": code, "client_id": c.id, "client_secret": c.secret, "redirect_uri": redirect,
                                        "grant_type": "authorization_code", "code_verifier": verifier])
        guard let refresh = r["refresh_token"] as? String else { throw ClipForgeError("Google did not return a refresh token.") }
        Keychain.set(refresh, for: tokenKey)
        store(r)
    }

    public func signOut() async {
        if let t = Keychain.get(tokenKey) {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("token=\(t)".utf8)
            _ = try? await URLSession.shared.data(for: req)
        }
        Keychain.set(nil, for: tokenKey)
        token = nil
    }

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let t = token, t.expires > Date().addingTimeInterval(60) { return t.value }
        guard let refresh = Keychain.get(tokenKey) else { throw ClipForgeError("Sign in to YouTube in Settings → Accounts.") }
        let c = try client()
        let r = try await tokenRequest(["refresh_token": refresh, "client_id": c.id, "client_secret": c.secret, "grant_type": "refresh_token"])
        return store(r)
    }

    @discardableResult
    func store(_ r: [String: Any]) -> String {
        let v = r["access_token"] as? String ?? ""
        token = (v, Date().addingTimeInterval(r["expires_in"] as? Double ?? 3000))
        return v
    }

    func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = Data((comps.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, o["access_token"] != nil else {
            if o["error"] as? String == "invalid_grant" { Keychain.set(nil, for: tokenKey) }
            throw ClipForgeError("Google sign-in failed: \(o["error_description"] as? String ?? o["error"] as? String ?? "unknown error"). Sign in again.")
        }
        return o
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect query.
final class LoopbackServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "clipforge.oauth")
    var continuation: CheckedContinuation<[String: String], Error>?
    var pending: [String: String]?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            // Handler runs on our serial queue; clearing it guarantees a single resume.
            listener.stateUpdateHandler = { [listener] st in
                switch st {
                case .ready: listener.stateUpdateHandler = nil; c.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let e): listener.stateUpdateHandler = nil; c.resume(throwing: e)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    func waitForRedirect(timeout: Double) async throws -> [String: String] {
        defer { listener.cancel() }
        return try await withThrowingTaskGroup(of: [String: String].self) { g in
            g.addTask {
                try await withCheckedThrowingContinuation { c in
                    self.queue.async {
                        if let p = self.pending { c.resume(returning: p) } else { self.continuation = c }
                    }
                }
            }
            g.addTask { try await Task.sleep(for: .seconds(timeout)); throw ClipForgeError("Sign-in timed out.") }
            let r = try await g.next()!
            g.cancelAll()
            queue.async { self.continuation?.resume(throwing: CancellationError()); self.continuation = nil }
            return r
        }
    }

    func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let line = String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\r\n").first ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://x" + path)?.queryItems ?? []
            guard !items.isEmpty else { conn.cancel(); return } // e.g. /favicon.ico
            let html = "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'><h2>ClipForge is connected.</h2><p>You can close this tab.</p></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            var q: [String: String] = [:]
            for i in items { q[i.name] = i.value }
            if let c = self.continuation { c.resume(returning: q); self.continuation = nil } else { self.pending = q }
        }
    }
}

// MARK: - Upload

public struct UploadRequest: Sendable {
    public var file: URL
    public var title: String
    public var description: String
    public var tags: [String]
    public var privacy: String
    public init(file: URL, title: String, description: String, tags: [String], privacy: String) {
        self.file = file; self.title = title; self.description = description; self.tags = tags; self.privacy = privacy
    }
}

public struct UploadResult: Sendable, Equatable { public var videoID: String; public var privacy: String; public var channelID: String }

public enum SessionState: Sendable, Equatable { case complete(UploadResult), partial(Int64), gone }

public enum PublishError: LocalizedError, Equatable {
    case quota, notSignedIn, sessionExpired, forbidden(String), failed(String)
    public var errorDescription: String? {
        switch self {
        case .quota: "YouTube API quota is used up for today (it resets at midnight Pacific time). Uploads cost ~1,600 units of the default 10,000/day."
        case .notSignedIn: "Sign in to YouTube in Settings → Accounts."
        case .sessionExpired: "The upload session expired; publish again to start a new upload."
        case .forbidden(let m): "YouTube refused the upload: \(m)"
        case .failed(let m): "Upload failed: \(m)"
        }
    }
}

public protocol Publishing: Actor {
    func channel() async throws -> Channel
    func startSession(_ r: UploadRequest) async throws -> URL
    func upload(_ r: UploadRequest, session: URL) async throws -> UploadResult
    func status(session: URL, size: Int64) async throws -> SessionState
}

/// YouTube Data API v3 `videos.insert` with resumable upload and exponential backoff.
public actor PublishService: Publishing {
    let auth: AccessTokenProviding
    let session: URLSession
    let sleep: @Sendable (Double) async throws -> Void
    var cachedChannel: Channel?

    public init(auth: AccessTokenProviding, session: URLSession = .shared,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.auth = auth; self.session = session; self.sleep = sleep
    }

    public func channel() async throws -> Channel {
        if let cachedChannel { return cachedChannel }
        let req = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true")!)
        let (data, _) = try await send(req)
        let item = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]])?.first
        guard let id = item?["id"] as? String else { throw ClipForgeError("This Google account has no YouTube channel.") }
        let c = Channel(id: id, title: (item?["snippet"] as? [String: Any])?["title"] as? String ?? id)
        cachedChannel = c
        return c
    }

    public func clearChannel() { cachedChannel = nil }

    static func metadata(_ r: UploadRequest) -> [String: Any] {
        var desc = r.description
        if !desc.localizedCaseInsensitiveContains("#shorts") { desc += (desc.isEmpty ? "" : "\n\n") + "#Shorts" }
        return [
            "snippet": ["title": HighlightLogic.shortsTitle(r.title), "description": String(desc.prefix(5000)),
                        "tags": r.tags, "categoryId": "22"],
            "status": ["privacyStatus": r.privacy, "selfDeclaredMadeForKids": false],
        ]
    }

    public func startSession(_ r: UploadRequest) async throws -> URL {
        let size = try Self.size(r.file)
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status")!)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        req.setValue("\(size)", forHTTPHeaderField: "X-Upload-Content-Length")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.metadata(r))
        let (_, resp) = try await send(req)
        guard let loc = resp.value(forHTTPHeaderField: "Location"), let u = URL(string: loc) else {
            throw PublishError.failed("YouTube did not return an upload session.")
        }
        return u
    }

    public func upload(_ r: UploadRequest, session url: URL) async throws -> UploadResult {
        let size = try Self.size(r.file)
        var offset: Int64 = 0
        for attempt in 0..<6 {
            switch try await status(session: url, size: size) {
            case .complete(let res): return res // already uploaded — never re-send
            case .gone: throw PublishError.sessionExpired
            case .partial(let o): offset = o
            }
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.timeoutInterval = 600
            req.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
            if offset > 0 { req.setValue("bytes \(offset)-\(size - 1)/\(size)", forHTTPHeaderField: "Content-Range") }
            let fh = try FileHandle(forReadingFrom: r.file)
            try fh.seek(toOffset: UInt64(offset))
            let body = fh.readDataToEndOfFile()
            try? fh.close()
            do {
                let (data, resp) = try await sendWithBackoff(req, body: body)
                if resp.statusCode == 200 || resp.statusCode == 201 { return try Self.result(data) }
            } catch let e as URLError where attempt < 5 {
                Log.publish.warning("Upload interrupted (\(e.code.rawValue)); resuming")
                try await sleep(pow(2, Double(attempt)))
            }
        }
        throw PublishError.failed("Upload did not complete after several retries.")
    }

    /// Query a resumable session (PUT with empty body + Content-Range: bytes */size).
    public func status(session url: URL, size: Int64) async throws -> SessionState {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
        let (data, resp) = try await rawSend(req, body: Data())
        switch resp.statusCode {
        case 200, 201: return .complete(try Self.result(data))
        case 308:
            // "Range: bytes=0-12345" → next offset 12346
            let last = resp.value(forHTTPHeaderField: "Range")?.split(separator: "-").last.flatMap { Int64($0) }
            return .partial(last.map { $0 + 1 } ?? 0)
        case 404, 410: return .gone
        default: throw Self.error(resp.statusCode, data)
        }
    }

    static func result(_ data: Data) throws -> UploadResult {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = o["id"] as? String else {
            throw PublishError.failed("Unexpected response from YouTube.")
        }
        return UploadResult(videoID: id,
                            privacy: (o["status"] as? [String: Any])?["privacyStatus"] as? String ?? "unknown",
                            channelID: (o["snippet"] as? [String: Any])?["channelId"] as? String ?? "")
    }

    static func size(_ u: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: transport

    func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) { try await sendWithBackoff(req, body: req.httpBody) }

    /// Retries 429/5xx and rate-limit 403s with exponential backoff; refreshes the token once on 401.
    func sendWithBackoff(_ req: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse) {
        var refreshed = false
        for attempt in 0..<6 {
            let (data, resp) = try await rawSend(req, body: body, forceRefresh: refreshed)
            let code = resp.statusCode
            if (200..<300).contains(code) || code == 308 { return (data, resp) }
            if code == 401, !refreshed { refreshed = true; continue }
            let reason = Self.reason(data)
            let retryable = code == 429 || code >= 500 || ["rateLimitExceeded", "userRateLimitExceeded", "backendError"].contains(reason)
            if retryable, attempt < 5 {
                Log.publish.warning("YouTube \(code) \(reason, privacy: .public); backing off")
                try await sleep(pow(2, Double(attempt)) + Double.random(in: 0...1))
                continue
            }
            throw Self.error(code, data)
        }
        throw PublishError.failed("YouTube kept failing; try again later.")
    }

    func rawSend(_ req: URLRequest, body: Data?, forceRefresh: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var r = req
        r.setValue("Bearer \(try await auth.accessToken(forceRefresh: forceRefresh))", forHTTPHeaderField: "Authorization")
        let (data, resp) = if let body, r.httpMethod != "GET" { try await session.upload(for: r, from: body) } else { try await session.data(for: r) }
        guard let http = resp as? HTTPURLResponse else { throw PublishError.failed("No HTTP response") }
        return (data, http)
    }

    static func reason(_ data: Data) -> String {
        let e = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any]
        return ((e?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? ""
    }

    static func error(_ code: Int, _ data: Data) -> PublishError {
        let e = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any]
        let msg = e?["message"] as? String ?? "HTTP \(code)"
        switch reason(data) {
        case "quotaExceeded", "dailyLimitExceeded": return .quota
        case "uploadLimitExceeded": return .forbidden("this channel hit YouTube's daily upload limit.")
        default: return code == 401 ? .notSignedIn : code == 403 ? .forbidden(msg) : .failed(msg)
        }
    }
}
