import Foundation

/// The iPhone companion talks to the Mac app over the local network (Bonjour + HTTP/JSON). The Mac does all the work and
/// holds every secret (Anthropic key, YouTube token); the phone only sends decisions and receives clips and numbers.
public enum CompanionAPI {
    public static let bonjourType = "_clipforge._tcp"
    public static let tokenHeader = "X-ClipForge-Token"
    public static let version = 1
}

public struct CompanionClip: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var status: String            // ClipStatus raw value
    public var statusLabel: String
    public var score: Int
    public var reason: String
    public var duration: Double
    public var sourceTitle: String
    public var createdAt: Date
    public var description: String
    public var hashtags: [String]
    public var hasVideo: Bool
    public var videoBytes: Int64
    public var titleOptions: [TitleOption]
    public var lastError: String?
    public var youtubeID: String?
    public init(id: UUID, title: String, status: String, statusLabel: String, score: Int, reason: String, duration: Double, sourceTitle: String,
                createdAt: Date, description: String, hashtags: [String], hasVideo: Bool, videoBytes: Int64, titleOptions: [TitleOption],
                lastError: String?, youtubeID: String?) {
        self.id = id; self.title = title; self.status = status; self.statusLabel = statusLabel; self.score = score; self.reason = reason
        self.duration = duration; self.sourceTitle = sourceTitle; self.createdAt = createdAt; self.description = description; self.hashtags = hashtags
        self.hasVideo = hasVideo; self.videoBytes = videoBytes; self.titleOptions = titleOptions; self.lastError = lastError; self.youtubeID = youtubeID
    }
    public var needsReview: Bool { status == "ready" }
}

public struct CompanionStatus: Codable, Sendable {
    public var macName: String
    public var running: String?          // source being processed
    public var stage: String?
    public var progress: Double?
    public var needsReview: Int
    public var youtubeSignedIn: Bool
    public var statsAvailable: Bool
    public var apiVersion = CompanionAPI.version
    public init(macName: String, running: String?, stage: String?, progress: Double?, needsReview: Int, youtubeSignedIn: Bool, statsAvailable: Bool) {
        self.macName = macName; self.running = running; self.stage = stage; self.progress = progress
        self.needsReview = needsReview; self.youtubeSignedIn = youtubeSignedIn; self.statsAvailable = statsAvailable
    }
}

public struct PairRequest: Codable, Sendable { public var code: String; public var deviceName: String; public init(code: String, deviceName: String) { self.code = code; self.deviceName = deviceName } }
public struct PairResponse: Codable, Sendable { public var token: String; public var macName: String; public init(token: String, macName: String) { self.token = token; self.macName = macName } }
public struct RejectRequest: Codable, Sendable { public var reason: String; public init(reason: String) { self.reason = reason } }
public struct TitleRequest: Codable, Sendable { public var title: String; public init(title: String) { self.title = title } }
public struct ActionResult: Codable, Sendable {
    public var ok: Bool; public var message: String
    public init(ok: Bool, message: String) { self.ok = ok; self.message = message }
}
