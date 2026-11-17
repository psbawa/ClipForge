import Foundation
import Network
import Security
@_exported import ClipForgeShared

/// Talks to the Mac's companion server. The Mac's port changes per launch, so it's re-resolved via Bonjour by name.
public struct CompanionClient: Sendable {
    public var base: URL
    public var token: String?

    public struct Failure: LocalizedError { public var message: String; public var status: Int; public var errorDescription: String? { message } }

    func request(_ method: String, _ path: String, body: Data? = nil, query: [String: String] = [:], timeout: TimeInterval = 30) -> URLRequest {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var r = URLRequest(url: c.url!, timeoutInterval: timeout)
        r.httpMethod = method
        if let token { r.setValue(token, forHTTPHeaderField: CompanionAPI.tokenHeader) }
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    func send<T: Decodable>(_ r: URLRequest, as: T.Type = T.self) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? Self.decoder.decode(ActionResult.self, from: data))?.message ?? "The Mac answered with HTTP \(status)."
            throw Failure(message: msg, status: status)
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    public func pair(code: String, deviceName: String) async throws -> PairResponse {
        try await send(request("POST", "v1/pair", body: try JSONEncoder().encode(PairRequest(code: code, deviceName: deviceName))))
    }
    public func status() async throws -> CompanionStatus { try await send(request("GET", "v1/status", timeout: 8)) }
    public func clips() async throws -> [CompanionClip] { try await send(request("GET", "v1/clips")) }
    public func stats() async throws -> ChannelSnapshot { try await send(request("GET", "v1/stats")) }
    public func action(_ id: UUID, _ name: String, body: Data? = nil, timeout: TimeInterval = 60) async throws -> CompanionClip {
        try await send(request("POST", "v1/clips/\(id.uuidString)/\(name)", body: body ?? Data("{}".utf8), timeout: timeout))
    }
    public func reject(_ id: UUID, reason: String) async throws {
        let _: ActionResult = try await send(request("POST", "v1/clips/\(id.uuidString)/reject", body: try JSONEncoder().encode(RejectRequest(reason: reason))))
    }
    public func data(_ path: String) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: request("GET", path, timeout: 300))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "Couldn't load \(path).", status: (resp as? HTTPURLResponse)?.statusCode ?? 0) }
        return data
    }
    public func download(_ id: UUID, to dest: URL) async throws {
        let (tmp, resp) = try await URLSession.shared.download(for: request("GET", "v1/clips/\(id.uuidString)/video", timeout: 600))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "The Mac couldn't send this video.", status: (resp as? HTTPURLResponse)?.statusCode ?? 0) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
    /// The Mac uploads the file to YouTube; the phone never holds YouTube credentials.
    public func upload(_ file: URL, title: String, description: String, tags: String, privacy: String, rightsConfirmed: Bool) async throws -> String {
        var r = request("POST", "v1/upload", query: ["title": title, "description": description, "tags": tags, "privacy": privacy,
                                                       "ext": file.pathExtension.isEmpty ? "mp4" : file.pathExtension], timeout: 3600)
        r.setValue(rightsConfirmed ? "yes" : "no", forHTTPHeaderField: "X-Rights-Confirmed")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: r, fromFile: file)
        let result = try Self.decoder.decode(ActionResult.self, from: data)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, result.ok else { throw Failure(message: result.message, status: (resp as? HTTPURLResponse)?.statusCode ?? 0) }
        return result.message
    }
}

/// A Mac advertising the companion service on this network.
public struct DiscoveredMac: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    var endpoint: NWEndpoint
}

/// Bonjour browsing + resolving a service to an IPv4 host:port URL.
@MainActor final class MacBrowser {
    private var browser: NWBrowser?
    var onChange: (([DiscoveredMac]) -> Void)?

    func start() {
        let b = NWBrowser(for: .bonjour(type: CompanionAPI.bonjourType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            let macs = results.compactMap { r -> DiscoveredMac? in
                if case .service(let name, _, _, _) = r.endpoint { return DiscoveredMac(name: name, endpoint: r.endpoint) }
                return nil
            }
            Task { @MainActor [weak self] in self?.onChange?(macs.sorted { $0.name < $1.name }) }
        }
        b.start(queue: .main)
        browser = b
    }
    func stop() { browser?.cancel(); browser = nil }

    /// Connects once to learn the address, then hands back http://ip:port.
    static func resolve(_ endpoint: NWEndpoint) async throws -> URL {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let c = NWConnection(to: endpoint, using: params)
        defer { c.cancel() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let once = Once()
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = c.currentPath?.remoteEndpoint, case .ipv4(let a) = host {
                        let ip = "\(a)".split(separator: "%").first.map(String.init) ?? "\(a)"
                        once.run { cont.resume(returning: URL(string: "http://\(ip):\(port.rawValue)")!) }
                    } else { once.run { cont.resume(throwing: CompanionClient.Failure(message: "Couldn't find the Mac's address.", status: 0)) } }
                case .failed(let e), .waiting(let e): once.run { cont.resume(throwing: CompanionClient.Failure(message: "Couldn't reach the Mac: \(e.localizedDescription)", status: 0)) }
                default: break
                }
            }
            c.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { once.run { cont.resume(throwing: CompanionClient.Failure(message: "The Mac didn't answer. Is ClipForge open on it?", status: 0)) } }
        }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func run(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; guard !done else { return }; done = true; f() }
}

/// Tiny Keychain wrapper for the pairing token.
enum MobileKeychain {
    static let service = "app.clipforge.mobile"
    @discardableResult
    static func set(_ v: String?, _ key: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard let v else { return true }
        var add = q; add[kSecValueData as String] = Data(v.utf8); add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}
