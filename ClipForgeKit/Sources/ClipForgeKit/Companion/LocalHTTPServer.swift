import Foundation
import Network

/// Minimal HTTP/1.1 server for the iPhone companion: one request per connection, Bonjour-advertised, local network only.
/// Bodies over 1 MB (video uploads) stream to a temp file instead of memory.
final class LocalHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]      // lower-cased names
        var body: Data
        var bodyFile: URL?
        var remote: String
    }
    struct Response: Sendable {
        var status: Int
        var contentType = "application/json"
        var body = Data()
        var file: URL?
        static func json<T: Encodable>(_ v: T, status: Int = 200) -> Response {
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            return Response(status: status, body: (try? e.encode(v)) ?? Data())
        }
        static func error(_ status: Int, _ message: String) -> Response { .json(ActionResult(ok: false, message: message), status: status) }
    }

    static let maxHeader = 16 * 1024
    static let maxBody: Int64 = 4 * 1024 * 1024 * 1024
    static let memoryBodyLimit = 1024 * 1024

    let queue = DispatchQueue(label: "clipforge.companion")
    var listener: NWListener?
    let handler: @Sendable (Request) async -> Response
    private(set) var port: UInt16?

    init(handler: @escaping @Sendable (Request) async -> Response) { self.handler = handler }

    func start(name: String, onReady: @escaping @Sendable (UInt16?) -> Void) throws {
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let l = try NWListener(using: params)
        l.service = NWListener.Service(name: name, type: CompanionAPI.bonjourType)
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.port = l.port?.rawValue; onReady(l.port?.rawValue)
            case .failed: onReady(nil)
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil; port = nil }

    func accept(_ c: NWConnection) {
        // Local network only: refuse anything that isn't a private/link-local/loopback address.
        if case .hostPort(let host, _) = c.endpoint, !Self.isLocal(host) { c.cancel(); return }
        c.start(queue: queue)
        Connection(c, server: self).readHeader()
    }

    static func isLocal(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            return b[0] == 10 || b[0] == 127 || (b[0] == 192 && b[1] == 168) || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 169 && b[1] == 254)
        case .ipv6(let a):
            let b = [UInt8](a.rawValue)
            return a == .loopback || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) || (b[0] & 0xFE) == 0xFC
                || (b[0...9].allSatisfy { $0 == 0 } && b[10] == 0xFF && b[11] == 0xFF && isLocal(.ipv4(IPv4Address(Data(b[12...15]))!)))
        default: return false
        }
    }

    final class Connection: @unchecked Sendable {
        let c: NWConnection; let server: LocalHTTPServer
        var buffer = Data()
        init(_ c: NWConnection, server: LocalHTTPServer) { self.c = c; self.server = server }

        func readHeader() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, done, err in
                if let data { buffer.append(data) }
                if let r = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buffer[..<r.lowerBound], as: UTF8.self)
                    let rest = buffer[r.upperBound...]
                    parse(head, rest: Data(rest))
                } else if buffer.count > LocalHTTPServer.maxHeader || done || err != nil {
                    respond(.error(400, "Bad request"))
                } else { readHeader() }
            }
        }

        func parse(_ head: String, rest: Data) {
            var lines = head.components(separatedBy: "\r\n")
            let first = lines.removeFirst().split(separator: " ")
            guard first.count >= 2 else { return respond(.error(400, "Bad request")) }
            var headers: [String: String] = [:]
            for l in lines { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
            let target = String(first[1])
            let comps = URLComponents(string: "http://x" + target)
            var query: [String: String] = [:]
            for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
            var remote = "?"
            if case .hostPort(let h, _) = c.endpoint { remote = "\(h)" }
            var req = Request(method: String(first[0]), path: comps?.path ?? target, query: query, headers: headers, body: Data(), bodyFile: nil, remote: remote)
            let length = Int64(headers["content-length"] ?? "0") ?? 0
            guard length >= 0, length <= LocalHTTPServer.maxBody else { return respond(.error(413, "Too large")) }
            if length == 0 { return dispatch(req) }
            if length <= LocalHTTPServer.memoryBodyLimit {
                readBody(into: rest, length: Int(length)) { [self] body in req.body = body; dispatch(req) }
            } else {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("cf-upload-\(UUID().uuidString)")
                FileManager.default.createFile(atPath: file.path, contents: rest)
                guard let h = try? FileHandle(forWritingTo: file) else { return respond(.error(500, "Can't store upload")) }
                h.seekToEndOfFile()
                stream(to: h, remaining: length - Int64(rest.count)) { [self] ok in
                    try? h.close()
                    guard ok else { try? FileManager.default.removeItem(at: file); return respond(.error(400, "Upload interrupted")) }
                    req.bodyFile = file; dispatch(req)
                }
            }
        }

        func readBody(into acc: Data, length: Int, done: @escaping (Data) -> Void) {
            if acc.count >= length { return done(acc.prefix(length)) }
            c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, end, err in
                guard let data, err == nil else { return respond(.error(400, "Bad body")) }
                let next = acc + data
                if next.count >= length || end { done(next.prefix(length)) } else { readBody(into: next, length: length, done: done) }
            }
        }

        func stream(to h: FileHandle, remaining: Int64, done: @escaping (Bool) -> Void) {
            if remaining <= 0 { return done(true) }
            c.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [self] data, _, end, err in
                guard let data, err == nil else { return done(false) }
                h.write(data)
                let left = remaining - Int64(data.count)
                if left <= 0 { done(true) } else if end { done(false) } else { stream(to: h, remaining: left, done: done) }
            }
        }

        func dispatch(_ req: Request) {
            Task { [self] in
                let r = await server.handler(req)
                if let f = req.bodyFile { try? FileManager.default.removeItem(at: f) }
                respond(r)
            }
        }

        func respond(_ r: Response) {
            let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 409: "Conflict", 413: "Payload Too Large", 429: "Too Many Requests", 500: "Server Error"][r.status] ?? "OK"
            var length = Int64(r.body.count)
            if let f = r.file { length = ((try? FileManager.default.attributesOfItem(atPath: f.path))?[.size] as? NSNumber)?.int64Value ?? 0 }
            let head = "HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: \(r.contentType)\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n"
            if let f = r.file, let h = try? FileHandle(forReadingFrom: f) {
                c.send(content: Data(head.utf8), completion: .contentProcessed { [self] _ in sendFile(h) })
            } else {
                c.send(content: Data(head.utf8) + r.body, completion: .contentProcessed { [self] _ in c.cancel() })
            }
        }

        func sendFile(_ h: FileHandle) {
            let chunk = h.readData(ofLength: 512 * 1024)
            if chunk.isEmpty { try? h.close(); return c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in c.cancel() }) }
            c.send(content: chunk, completion: .contentProcessed { [self] err in if err != nil { try? h.close(); c.cancel() } else { sendFile(h) } })
        }
    }
}
