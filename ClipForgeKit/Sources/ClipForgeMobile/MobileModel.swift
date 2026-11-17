import Foundation
import Observation
#if canImport(Photos)
import Photos
#endif

/// iPhone companion state. Everything heavy happens on the Mac; this keeps the list, the cache and the connection.
@MainActor @Observable public final class MobileModel {
    public enum Connection: Equatable { case unpaired, searching, connected, offline(String) }

    public private(set) var connection: Connection = .unpaired
    public private(set) var macName = ""
    private var token: String?
    public private(set) var discovered: [DiscoveredMac] = []
    public private(set) var status: CompanionStatus?
    public private(set) var clips: [CompanionClip] = []
    public private(set) var stats: ChannelSnapshot?
    public private(set) var busy: Set<String> = []            // "approve:<id>", "refresh", "upload" …
    public var message: String?                               // transient banner text
    public var uploadProgress: Double?

    @ObservationIgnored var client: CompanionClient?
    @ObservationIgnored let browser = MacBrowser()
    static let keys = (mac: "companion.macName", token: "companion.token", manual: "companion.manualURL")

    public init() {
        macName = UserDefaults.standard.string(forKey: Self.keys.mac) ?? ""
        token = MobileKeychain.get(Self.keys.token)
        browser.onChange = { [weak self] macs in
            guard let self else { return }
            self.discovered = macs
            if self.isPaired, self.client == nil, let m = macs.first(where: { $0.name == self.macName }) { Task { await self.connect(m) } }
        }
        browser.start()
        if isPaired {
            connection = .searching
            if let manual = UserDefaults.standard.string(forKey: Self.keys.manual), let url = URL(string: manual) {
                client = CompanionClient(base: url, token: token)
                Task { await refresh() }
            }
        }
    }

    public var isPaired: Bool { token != nil && !macName.isEmpty }
    public var reviewQueue: [CompanionClip] { clips.filter(\.needsReview) }

    // MARK: Pairing

    public func pair(_ mac: DiscoveredMac, code: String) async -> Bool {
        do { return try await pair(base: try await MacBrowser.resolve(mac.endpoint), name: mac.name, code: code, manual: false) }
        catch { message = error.localizedDescription; return false }
    }

    /// Fallback when Bonjour is blocked (some routers): type the Mac's address shown in Settings → iPhone.
    public func pair(address: String, code: String) async -> Bool {
        let a = address.hasPrefix("http") ? address : "http://" + address
        guard let url = URL(string: a), url.host != nil else { message = "That address doesn't look right (example: 192.168.1.20:52000)."; return false }
        do { return try await pair(base: url, name: url.host ?? "Mac", code: code, manual: true) }
        catch { message = error.localizedDescription; return false }
    }

    func pair(base: URL, name: String, code: String, manual: Bool) async throws -> Bool {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { message = "Enter the 6-digit code shown on the Mac."; return false }
        let r = try await CompanionClient(base: base, token: nil).pair(code: digits, deviceName: Self.deviceName)
        if !MobileKeychain.set(r.token, Self.keys.token) { message = "Paired, but the iPhone couldn't store the pairing securely; you may need to pair again after restarting the app." }
        token = r.token
        macName = name
        UserDefaults.standard.set(macName, forKey: Self.keys.mac)
        UserDefaults.standard.set(manual ? base.absoluteString : nil, forKey: Self.keys.manual)
        client = CompanionClient(base: base, token: r.token)
        await refresh()
        return true
    }

    public func unpair() {
        MobileKeychain.set(nil, Self.keys.token)
        token = nil
        UserDefaults.standard.removeObject(forKey: Self.keys.mac)
        UserDefaults.standard.removeObject(forKey: Self.keys.manual)
        client = nil; macName = ""; clips = []; stats = nil; status = nil; connection = .unpaired
        try? FileManager.default.removeItem(at: Self.cacheDir)
    }

    func connect(_ mac: DiscoveredMac) async {
        do {
            client = CompanionClient(base: try await MacBrowser.resolve(mac.endpoint), token: token)
            await refresh()
        } catch { connection = .offline(error.localizedDescription) }
    }

    static var deviceName: String {
        #if os(iOS)
        return ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        #else
        return Host.current().localizedName ?? "Device"
        #endif
    }

    // MARK: Data

    public func refresh() async {
        guard let client else {
            connection = isPaired ? .searching : .unpaired
            if isPaired, let m = discovered.first(where: { $0.name == macName }) { await connect(m) }
            return
        }
        busy.insert("refresh"); defer { busy.remove("refresh") }
        do {
            status = try await client.status()
            clips = try await client.clips()
            connection = .connected
            if status?.statsAvailable == true { stats = try? await client.stats() }
        } catch let f as CompanionClient.Failure where f.status == 401 {
            unpair(); message = f.message
        } catch {
            connection = .offline("Can't reach \(macName). Make sure ClipForge is open on the Mac and both are on the same Wi-Fi.")
            self.client = nil
        }
    }

    func run(_ key: String, _ body: (CompanionClient) async throws -> Void) async {
        guard let client else { message = "Not connected to the Mac."; return }
        busy.insert(key); defer { busy.remove(key) }
        do { try await body(client) } catch { message = error.localizedDescription }
    }

    func replace(_ c: CompanionClip) { if let i = clips.firstIndex(where: { $0.id == c.id }) { clips[i] = c } }

    public func approve(_ c: CompanionClip) async { await run("approve:\(c.id)") { replace(try await $0.action(c.id, "approve")) } }
    public func publish(_ c: CompanionClip) async {
        await run("publish:\(c.id)") { replace(try await $0.action(c.id, "publish", timeout: 1800)); message = "Published to YouTube." }
    }
    public func reject(_ c: CompanionClip, reason: String) async {
        await run("reject:\(c.id)") { try await $0.reject(c.id, reason: reason); clips.removeAll { $0.id == c.id } }
    }
    public func setTitle(_ c: CompanionClip, _ title: String) async {
        await run("title:\(c.id)") { replace(try await $0.action(c.id, "title", body: try JSONEncoder().encode(TitleRequest(title: title)))) }
    }
    public func suggestTitles(_ c: CompanionClip) async {
        await run("titles:\(c.id)") { replace(try await $0.action(c.id, "suggest-titles", timeout: 180)) }
    }
    public func isBusy(_ key: String) -> Bool { busy.contains(key) }

    public func thumbnail(_ c: CompanionClip) async -> Data? {
        let f = Self.cacheDir.appendingPathComponent("\(c.id.uuidString).jpg")
        if let d = try? Data(contentsOf: f) { return d }
        guard let client, let d = try? await client.data("v1/clips/\(c.id.uuidString)/thumb") else { return nil }
        try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        try? d.write(to: f)
        return d
    }

    /// Downloads the clip once; later plays/saves come from the cache.
    public func video(_ c: CompanionClip) async -> URL? {
        let f = Self.cacheDir.appendingPathComponent("\(c.id.uuidString)-\(c.videoBytes).mp4")
        if FileManager.default.fileExists(atPath: f.path) { return f }
        guard let client else { message = "Not connected to the Mac."; return nil }
        busy.insert("video:\(c.id)"); defer { busy.remove("video:\(c.id)") }
        do {
            try FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
            try await client.download(c.id, to: f)
            return f
        } catch { message = error.localizedDescription; return nil }
    }

    public func saveToPhotos(_ c: CompanionClip) async {
        #if canImport(Photos) && os(iOS)
        guard let url = await video(c) else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { message = "Allow ClipForge to add to Photos in Settings → Privacy → Photos."; return }
        do {
            try await PHPhotoLibrary.shared().performChanges { _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
            message = "Saved to Photos."
        } catch { message = "Couldn't save: \(error.localizedDescription)" }
        #endif
    }

    public func upload(_ file: URL, title: String, description: String, tags: String, privacy: String, rightsConfirmed: Bool) async -> String? {
        guard let client else { message = "Not connected to the Mac."; return nil }
        busy.insert("upload"); defer { busy.remove("upload") }
        do {
            let id = try await client.upload(file, title: title, description: description, tags: tags, privacy: privacy, rightsConfirmed: rightsConfirmed)
            message = "Uploaded to YouTube."
            return id
        } catch { message = error.localizedDescription; return nil }
    }

    static var cacheDir: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipForgeClips") }
}
