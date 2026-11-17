import Foundation
import os
import Security

public enum Log {
    public static let app = Logger(subsystem: "app.clipforge", category: "app")
    public static let ingest = Logger(subsystem: "app.clipforge", category: "ingest")
    public static let ai = Logger(subsystem: "app.clipforge", category: "ai")
    public static let publish = Logger(subsystem: "app.clipforge", category: "publish")
}

public struct ClipForgeError: LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - External binaries

public struct Binaries: Sendable {
    public let ytdlp: URL
    public let ffmpeg: URL

    public static let setupHint = "ClipForge needs yt-dlp and ffmpeg. Install them with:\n\nbrew install yt-dlp ffmpeg"

    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? [])

    public static func locate(_ name: String) -> URL? {
        searchDirs.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// nil when either tool is missing; UI shows `setupHint`.
    public static func detect() -> Binaries? {
        guard let y = locate("yt-dlp"), let f = locate("ffmpeg") else { return nil }
        return Binaries(ytdlp: y, ffmpeg: f)
    }
}

public enum Shell {
    /// Runs a process to completion and returns stdout. Throws with stderr tail on non-zero exit.
    @discardableResult
    public static func run(_ exe: URL, _ args: [String]) async throws -> String {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        // Read pipes concurrently so large output can't deadlock the child.
        async let o = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        async let e = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                p.terminationHandler = { _ in c.resume() }
                do { try p.run() } catch {
                    p.terminationHandler = nil
                    try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
                    c.resume(throwing: error)
                }
            }
        } onCancel: { p.terminate() }
        let (od, ed) = await (o, e)
        guard p.terminationStatus == 0 else {
            let tail = String(decoding: ed.suffix(800), as: UTF8.self)
            throw ClipForgeError("\(exe.lastPathComponent) failed (\(p.terminationStatus)): \(tail)")
        }
        return String(decoding: od, as: UTF8.self)
    }

    /// Runs to completion and returns stderr (ffmpeg's analysis filters report there), regardless of exit status.
    static func runCapturingStderr(_ exe: URL, _ args: [String]) async throws -> String {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = env
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        try p.run()
        // Reading to EOF returns once the process closes stderr, i.e. when it exits — never blocks the caller's thread.
        let data = await Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
        return String(decoding: data, as: UTF8.self)
    }

    /// Homebrew tools (ffmpeg via yt-dlp) must be on PATH for the child.
    static let env: [String: String] = {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = (Binaries.searchDirs + [e["PATH"] ?? ""]).joined(separator: ":")
        return e
    }()
}

// MARK: - Keychain

public enum Keychain {
    static let service = "app.clipforge"

    public static func set(_ value: String?, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Log.app.error("Keychain write failed: \(status)") }
    }

    public static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public enum Key {
        public static let anthropic = "anthropic.apiKey"
        public static let googleClientID = "google.clientID"
        public static let googleClientSecret = "google.clientSecret"
        public static let googleRefreshToken = "google.refreshToken"
        public static let googleAnalyticsRefreshToken = "google.analyticsRefreshToken"
        public static let companionDevices = "companion.devices"
        public static let elevenLabs = "elevenlabs.apiKey"
    }
}

public enum Paths {
    /// Tests point this at a temp dir so they never write into ~/Movies.
    nonisolated(unsafe) static var rootOverride: URL?
    /// Tests: per-task root that wins over `rootOverride`, so parallel end-to-end suites can't move each other's folders.
    @TaskLocal static var scopedRoot: URL?

    public static var root: URL {
        let u = scopedRoot ?? rootOverride ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipForge")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    public static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipForge")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    public static func dir(_ parts: String...) -> URL {
        let u = parts.reduce(root) { $0.appendingPathComponent($1) }
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
