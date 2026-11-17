import Foundation

public enum VlogOutput: String, Codable, Sendable, CaseIterable, Identifiable {
    case full, shorts, both
    public var id: String { rawValue }
    public var label: String { ["full": "Full-length vlog", "shorts": "Shorts", "both": "Both"][rawValue]! }
}

public enum VlogVibe: String, Codable, Sendable, CaseIterable, Identifiable {
    case cinematic, upbeat, calm, adventure
    public var id: String { rawValue }
    public var label: String { ["cinematic": "Cinematic", "upbeat": "Upbeat & fun", "calm": "Calm & aesthetic", "adventure": "Adventure"][rawValue]! }
    var mood: StoryTone { [.cinematic: .epic, .upbeat: .funny, .calm: .chill, .adventure: .hype][self]! }
    var color: String { [.cinematic: "cinematic", .upbeat: "punchy", .calm: "muted", .adventure: "warm"][self]! }
    var styleID: String { [.cinematic: "travel-cinematic", .upbeat: "reels-lifestyle", .calm: "aesthetic-vlog", .adventure: "travel-cinematic"][self]! }
}

public struct VlogOptions: Codable, Sendable, Equatable {
    public var output: VlogOutput = .both
    public var fullMinutes: Double = 0           // 0 = auto
    public var shortsCount = 3
    public var shortSeconds: Double = 30
    public var vibe: VlogVibe = .cinematic
    public var title = ""
    public var places = ""
    public var prompt = ""
    public var excluded: [String] = []           // asset ids the user excluded
    public var cleanupProxies = true
    public init() {}
}

/// One imported file (video or photo) with its metadata and analysis.
public struct VlogAsset: Codable, Sendable, Hashable, Identifiable {
    public var id: String                        // stable fingerprint (path + size + mtime)
    public var path: String
    public var isPhoto: Bool
    public var captured: Date
    public var latitude: Double?
    public var longitude: Double?
    public var duration: Double                  // photos: 0
    public var width: Int
    public var height: Int
    public var proxyPath: String?
    public var hasAudio = true
    // Analysis (filled by ShotAnalyzer, cached)
    public var analyzed = false
    public var sharpness = 0.0                   // 0–1
    public var brightness = 0.0                  // 0–1 mean luma
    public var shake = 0.0                       // 0–1
    public var rejected: String?                 // why the shot was dropped
    public var duplicateOf: String?
    public var talking = false                   // vlogger talking to camera
    public var score = 0.0                       // 0–100
    public var goodRanges: [[Double]] = []       // usable sub-ranges (seconds)
    public var words: [Word] = []
    public var chapter: Int?
    public var fingerprint: [UInt8] = []         // 64×36 gray mean frame, for duplicate detection
    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.lastPathComponent }
}

public struct VlogChapter: Codable, Sendable, Hashable {
    public var index: Int
    public var title: String
    public var place: String?
    public var start: Date
    public var end: Date
    public var assetIDs: [String]
}

/// The edit decision lists: one full vlog and/or several shorts. Beats reference assets by id.
public struct VlogPlan: Codable, Sendable, Equatable {
    public var full: Storyboard?
    public var shorts: [Storyboard] = []
    public var chapterMarks: [String] = []       // "00:00 Intro" lines for the YouTube description
    public var all: [Storyboard] { (full.map { [$0] } ?? []) + shorts }
}
