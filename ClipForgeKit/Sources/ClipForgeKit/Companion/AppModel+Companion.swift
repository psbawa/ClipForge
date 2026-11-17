import AVFoundation
import SwiftData
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A paired iPhone. Only a SHA-256 of its token is stored (Keychain).
public struct PairedDevice: Codable, Sendable, Identifiable, Hashable {
    public var id: String { tokenHash }
    public var name: String
    public var tokenHash: String
    public var added: Date
    static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func load() -> [PairedDevice] {
        Keychain.get(Keychain.Key.companionDevices).flatMap { try? JSONDecoder().decode([PairedDevice].self, from: Data($0.utf8)) } ?? []
    }
    static func save(_ d: [PairedDevice]) {
        Keychain.set(d.isEmpty ? nil : String(decoding: (try? JSONEncoder().encode(d)) ?? Data(), as: UTF8.self), for: Keychain.Key.companionDevices)
    }
}

enum CompanionConfig {
    static let pairCodeLifetime: TimeInterval = 180
    static let maxFailedPairs = 5
    static let thumbWidth = 360
}

extension AppModel {
    // MARK: Lifecycle

    public func setCompanion(enabled: Bool) {
        settings.companionEnabled = enabled
        if enabled { startCompanion() } else { stopCompanion() }
    }

    func startCompanion() {
        guard companion == nil else { return }
        let server = LocalHTTPServer { [weak self] req in
            guard let self else { return .error(500, "Not running") }
            return await self.handleCompanion(req)
        }
        do {
            try server.start(name: "ClipForge on \(Host.current().localizedName ?? "Mac")") { [weak self] port in
                Task { @MainActor in
                    self?.companionPort = port
                    if port == nil { self?.notify("The iPhone companion couldn't start (local network port unavailable).") }
                }
            }
            companion = server
        } catch { notify("The iPhone companion couldn't start: \(error.localizedDescription)") }
    }

    func stopCompanion() {
        companion?.stop(); companion = nil; companionPort = nil; companionPairCode = nil
    }

    /// Shows a 6-digit code on the Mac for 3 minutes; entering it on the phone pairs that phone.
    public func newPairCode() {
        companionPairCode = String(format: "%06d", Int.random(in: 0...999_999))
        companionPairExpires = Date().addingTimeInterval(CompanionConfig.pairCodeLifetime)
        companionFailedPairs = 0
    }

    public func unpair(_ d: PairedDevice) {
        companionDevices.removeAll { $0 == d }
        PairedDevice.save(companionDevices)
    }

    // MARK: Routing

    func handleCompanion(_ r: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        let parts = r.path.split(separator: "/").map(String.init)
        guard parts.first == "v1" else { return .error(404, "Not found") }
        if r.method == "POST", parts == ["v1", "pair"] { return pair(r) }
        guard let token = r.headers[CompanionAPI.tokenHeader.lowercased()],
              companionDevices.contains(where: { $0.tokenHash == PairedDevice.hash(token) }) else {
            return .error(401, "This iPhone isn't paired. Pair it again from the Mac (Settings → iPhone).")
        }
        switch (r.method, Array(parts.dropFirst())) {
        case ("GET", ["status"]): return .json(companionStatus())
        case ("GET", ["clips"]): return .json(companionClips())
        case ("GET", ["stats"]): return channelStats.map { .json($0) } ?? .error(404, "Channel Stats aren't loaded on the Mac yet.")
        case ("POST", ["upload"]): return await companionUpload(r)
        case (let m, let p) where p.count >= 2 && p[0] == "clips":
            guard let id = UUID(uuidString: p[1]), let rec = clip(id) else { return .error(404, "That clip no longer exists.") }
            return await clipRoute(m, Array(p.dropFirst(2)), rec, r)
        default: return .error(404, "Not found")
        }
    }

    func pair(_ r: LocalHTTPServer.Request) -> LocalHTTPServer.Response {
        guard let req = try? JSONDecoder().decode(PairRequest.self, from: r.body) else { return .error(400, "Bad pairing request") }
        guard let code = companionPairCode, Date() < companionPairExpires else { return .error(409, "No pairing code is active. On the Mac: Settings → iPhone → Pair iPhone.") }
        guard req.code == code else {
            companionFailedPairs += 1
            if companionFailedPairs >= CompanionConfig.maxFailedPairs { companionPairCode = nil }
            return .error(401, companionPairCode == nil ? "Too many wrong codes. Make a new code on the Mac." : "Wrong code.")
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64URL
        companionDevices.append(PairedDevice(name: String(req.deviceName.prefix(60)), tokenHash: PairedDevice.hash(token), added: .now))
        PairedDevice.save(companionDevices)
        companionPairCode = nil
        notify("Paired \(req.deviceName).", .info)
        return .json(PairResponse(token: token, macName: Host.current().localizedName ?? "Mac"))
    }

    func clipRoute(_ method: String, _ rest: [String], _ rec: ClipRecord, _ r: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        switch (method, rest) {
        case ("GET", []): return .json(companionClip(rec))
        case ("GET", ["video"]):
            guard let v = rec.videoURL, FileManager.default.fileExists(atPath: v.path) else { return .error(404, "The video file is missing on the Mac.") }
            return LocalHTTPServer.Response(status: 200, contentType: "video/mp4", file: v)
        case ("GET", ["thumb"]):
            guard let t = await companionThumb(rec) else { return .error(404, "No thumbnail") }
            return LocalHTTPServer.Response(status: 200, contentType: "image/jpeg", body: t)
        case ("POST", ["approve"]): approve(rec)
        case ("POST", ["reject"]):
            let reason = (try? JSONDecoder().decode(RejectRequest.self, from: r.body))?.reason
            reject(rec, reason: reason?.isEmpty == false ? reason : nil)
            return .json(ActionResult(ok: true, message: "Rejected and deleted."))
        case ("POST", ["publish"]):
            await approveAndPublish(rec)
            if rec.status != .published { return .json(ActionResult(ok: false, message: rec.lastError ?? "Not published."), status: 409) }
        case ("POST", ["title"]):
            guard let t = try? JSONDecoder().decode(TitleRequest.self, from: r.body), !t.title.trimmingCharacters(in: .whitespaces).isEmpty else { return .error(400, "Empty title") }
            rec.title = HighlightLogic.shortsTitle(t.title); save()
        case ("POST", ["suggest-titles"]): await suggestTitles(rec)
        default: return .error(404, "Not found")
        }
        return .json(companionClip(rec))
    }

    // MARK: Payloads

    func companionStatus() -> CompanionStatus {
        let clips = (try? context.fetch(FetchDescriptor<ClipRecord>())) ?? []
        return CompanionStatus(macName: Host.current().localizedName ?? "Mac", running: runningSourceID.flatMap { id in source(id)?.title },
                               stage: runningSourceID == nil ? nil : stage.rawValue, progress: progress,
                               needsReview: clips.filter { $0.status == .ready }.count, youtubeSignedIn: youtubeChannel != nil, statsAvailable: channelStats != nil)
    }

    func companionClips() -> [CompanionClip] {
        let clips = (try? context.fetch(FetchDescriptor<ClipRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        return clips.filter { ![.rendering, .rejected].contains($0.status) }.prefix(300).map(companionClip)
    }

    func companionClip(_ c: ClipRecord) -> CompanionClip {
        let size = c.videoURL.flatMap { ((try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? NSNumber)?.int64Value } ?? 0
        return CompanionClip(id: c.id, title: c.title, status: c.status.rawValue, statusLabel: c.status.label, score: c.effectiveScore, reason: c.reason,
                             duration: c.end - c.start, sourceTitle: c.source?.title ?? "", createdAt: c.createdAt, description: c.fullDescription,
                             hashtags: c.hashtags, hasVideo: size > 0, videoBytes: size, titleOptions: c.titleOptions, lastError: c.lastError, youtubeID: c.videoID)
    }

    func clip(_ id: UUID) -> ClipRecord? {
        (try? context.fetch(FetchDescriptor<ClipRecord>(predicate: #Predicate { $0.id == id })))?.first
    }

    func companionThumb(_ rec: ClipRecord) async -> Data? {
        guard let v = rec.videoURL else { return nil }
        let cache = Paths.dir("companion-thumbs").appendingPathComponent("\(rec.id.uuidString).jpg")
        if let d = try? Data(contentsOf: cache) { return d }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: v))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: CompanionConfig.thumbWidth, height: CompanionConfig.thumbWidth * 2)
        guard let img = try? await gen.image(at: CMTime(seconds: max(0.5, (rec.end - rec.start) * 0.3), preferredTimescale: 600)).image else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        try? (out as Data).write(to: cache)
        return out as Data
    }

    /// A video sent from the phone, uploaded to YouTube by the Mac (the phone never holds YouTube credentials).
    func companionUpload(_ r: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        guard let body = r.bodyFile ?? (r.body.isEmpty ? nil : { let f = FileManager.default.temporaryDirectory.appendingPathComponent("cf-up-\(UUID().uuidString)"); try? r.body.write(to: f); return f }())
        else { return .error(400, "No video was sent.") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(r.query["ext"] ?? "mp4")")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try FileManager.default.copyItem(at: body, to: file)
            let id = try await uploadLocalFile(file, title: r.query["title"] ?? "", description: r.query["description"] ?? "",
                                               tags: (r.query["tags"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                               privacy: ["private", "unlisted", "public"].contains(r.query["privacy"] ?? "") ? r.query["privacy"]! : settings.privacyStatus,
                                               rightsConfirmed: r.headers["x-rights-confirmed"] == "yes")
            return .json(ActionResult(ok: true, message: id))
        } catch { return .json(ActionResult(ok: false, message: error.localizedDescription), status: 409) }
    }
}
