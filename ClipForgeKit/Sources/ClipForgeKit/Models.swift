import Foundation

/// All times are "session seconds": seconds since capture start (live) or since video start (VOD).
public struct Word: Codable, Sendable, Hashable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(_ text: String, _ start: Double, _ end: Double) { self.text = text; self.start = start; self.end = end }

    public var endsSentence: Bool {
        guard let c = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?…".contains(c)
    }
}

public extension Array where Element == Word {
    func slice(_ from: Double, _ to: Double) -> [Word] { filter { $0.end > from && $0.start < to } }
    var joinedText: String { map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }

    /// Transcript rendered with second marks so the model can return absolute times.
    var timestampedText: String {
        var lines: [String] = [], line: [String] = [], lineStart = first?.start ?? 0
        for w in self {
            if line.isEmpty { lineStart = w.start }
            line.append(w.text.trimmingCharacters(in: .whitespaces))
            if w.endsSentence || line.count >= 25 {
                lines.append("[\(String(format: "%.1f", lineStart))] " + line.joined(separator: " "))
                line = []
            }
        }
        if !line.isEmpty { lines.append("[\(String(format: "%.1f", lineStart))] " + line.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }
}

public struct Highlight: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var title: String
    public var hook: String
    public var score: Int
    public var reason: String
    public var description: String = ""
    public var tags: [String] = []
    /// Set once Stage B has ranked this candidate.
    public var finalScore: Int?
    /// The scored moment itself (before boundary snapping). Clips always contain it whole.
    public var coreStart: Double = 0
    public var coreEnd: Double = 0
    /// Signal breakdown (0–100 each) from the selection pass, for "Picked because".
    public var signals: [String: Int] = [:]

    public init(start: Double, end: Double, title: String, hook: String, score: Int, reason: String) {
        self.start = start; self.end = end; self.title = title; self.hook = hook; self.score = score; self.reason = reason
        coreStart = start; coreEnd = end
    }
    public var duration: Double { end - start }
    public var effectiveScore: Int { finalScore ?? score }
}

public enum CaptionStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case pop, clean, boxed
    public var id: String { rawValue }
    public var label: String { ["pop": "Bold Pop", "clean": "Clean", "boxed": "Boxed"][rawValue]! }
}

public enum PublishMode: String, Codable, Sendable, CaseIterable { case review, auto }

public struct ModelPrice: Codable, Sendable, Hashable {
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    public init(_ i: Double, _ o: Double) { inputPerMTok = i; outputPerMTok = o }
}

public struct AppSettings: Codable, Sendable, Equatable {
    // Transcription
    /// large-v3 turbo: far fewer mishearings than base.en (measured on a real video); ~14× realtime on Apple Silicon.
    public var whisperModel = AppSettings.defaultWhisperModel
    public static let defaultWhisperModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    // Highlights
    public var fastModel = "claude-haiku-5-5"
    public var strongModel = "claude-sonnet-5-5"
    public var windowSeconds: Double = 360
    public var stepSeconds: Double = 90
    public var stageBThreshold = 70
    public var minClipSeconds: Double = 20
    public var maxClipSeconds: Double = 59
    public var hardMaxSeconds: Double = 180
    public var prices: [String: ModelPrice] = ["claude-haiku-5-5": .init(0.10, 0.50), "claude-sonnet-5-5": .init(2.0, 10.0)]
    /// 0 = no cap.
    public var dailyBudgetUSD: Double = 0
    // Clips
    /// Every finished video gets at least this many clips: its best moments, even below the thresholds. 0 = thresholds only.
    public var minClipsPerVideo = 3
    public var preRoll: Double = 1.0
    public var postRoll: Double = 1.0
    public var captionStyle: CaptionStyle = .pop
    public var bufferMinutes: Double = 30
    // Publishing
    public var publishMode: PublishMode = .review
    public var autoPublishKilled = false
    public var maxPerHour = 2
    public var maxPerDay = 6
    public var minAutoScore = 80
    public var minGapMinutes: Double = 20
    public var privacyStatus = "private"
    // Pro Editor for highlight clips: nil = Auto (picked per video), "none" = plain, else a profile id.
    public var clipStyleID: String?
    public var clipIntensity = 0.5
    public var trendRefreshEnabled = true
    /// Visual clipper: "auto" (detected from sounds/HUD) or a GenreConfig id.
    public var gameGenre = "auto"
    /// Serve the iPhone companion on the local network.
    public var companionEnabled = false

    public init() {}

    static let key = "settings.v1"
    /// Stored values overlaid on defaults, so adding a setting in an update never wipes the user's others.
    public static func load(_ defaults: UserDefaults = .standard) -> AppSettings {
        guard let d = defaults.data(forKey: key),
              let stored = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let encoded = try? JSONEncoder().encode(AppSettings()),
              var base = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else { return .init() }
        base.merge(stored) { _, new in new }
        // The old default (base.en) mishears a lot; move anyone still on it to the new default.
        if base["whisperModel"] as? String == "openai_whisper-base.en" { base["whisperModel"] = defaultWhisperModel }
        guard let merged = try? JSONSerialization.data(withJSONObject: base),
              let s = try? JSONDecoder().decode(AppSettings.self, from: merged) else { return .init() }
        return s
    }
    public func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}
