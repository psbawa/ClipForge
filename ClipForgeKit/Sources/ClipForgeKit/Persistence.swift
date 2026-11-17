import Foundation
import SwiftData

public enum ClipStatus: String, Codable, Sendable, CaseIterable {
    case rendering, ready, approved, publishing, published, downloaded, rejected, failed
    public var label: String {
        ["rendering": "Rendering", "ready": "Needs review", "approved": "Approved", "publishing": "Publishing",
         "published": "Published", "downloaded": "Downloaded", "rejected": "Rejected", "failed": "Failed"][rawValue]!
    }
}

/// What a failed clip was doing, so Retry repeats the right step.
public enum ClipFailure: String, Codable, Sendable { case render, publish }

@Model public final class Source {
    @Attribute(.unique) public var id: UUID
    public var url: String
    public var title: String
    public var channelID: String
    public var channelName: String
    public var isLive: Bool
    public var createdAt: Date
    /// "I own this content or have permission from the rights holder."
    public var ownershipConfirmedAt: Date?
    /// Extra confirmation required when the source channel ≠ the authenticated channel.
    public var permissionConfirmedAt: Date?
    public var permissionNote: String
    /// True while a pipeline was running; used to offer resume after a crash.
    public var wasRunning: Bool
    /// VOD: highlight windows scored up to here (session seconds), so a resume doesn't re-pay for them.
    public var scoredUntil: Double = 0
    public var duration: Double?
    /// Time ranges of clips the user rejected (and that were deleted), so re-runs never cut them again.
    public var rejectedRangesData: Data?
    @Relationship(deleteRule: .cascade, inverse: \ClipRecord.source) public var clips: [ClipRecord] = []

    public init(url: String, info: SourceInfo) {
        id = UUID(); self.url = url; title = info.title; channelID = info.channelID; channelName = info.channelName
        isLive = info.isLive; createdAt = .now; permissionNote = ""; wasRunning = false
    }

    public var folder: URL { Paths.dir("sources", id.uuidString) }

    public var rejectedRanges: [[Double]] {
        get { rejectedRangesData.flatMap { try? JSONDecoder().decode([[Double]].self, from: $0) } ?? [] }
        set { rejectedRangesData = try? JSONEncoder().encode(newValue) }
    }
}

@Model public final class ClipRecord {
    @Attribute(.unique) public var id: UUID
    public var source: Source?
    public var start: Double
    public var end: Double
    public var title: String
    public var hook: String
    public var descriptionText: String
    public var tags: [String]
    public var score: Int
    public var finalScore: Int?
    public var reason: String
    public var statusRaw: String
    public var captionStyleRaw: String
    public var videoPath: String?
    public var srtPath: String?
    public var createdAt: Date
    public var uploadSessionURL: String?
    public var videoID: String?
    public var publishedAt: Date?
    public var lastError: String?
    public var failureRaw: String?
    public var rejectReason: String?
    public var hashtags: [String] = []
    /// The scored moment (session seconds); 0/0 on clips made before this existed.
    public var coreStart: Double = 0
    public var coreEnd: Double = 0
    /// Caption text edited in review (session-time words); nil = use the transcript.
    public var captionWordsData: Data?
    public var exportedPath: String?
    /// Framing override: "smart" (default) / "blur" / "manual:<x>".
    public var framingRaw: String?
    public var framingSummary: String?
    /// Why this moment was picked: per-signal scores (0–100) from the selection pass.
    public var signalsData: Data?
    /// Optional voiceover: settings/script, and the generated track (lines + audio paths + word timings).
    public var voiceoverData: Data?
    public var voiceTrackData: Data?
    /// Set when this clip is the output of a Story Shorts / Highlight Remix job (edit plan lives on the job).
    public var storyJobID: UUID?
    /// Pro Editor style applied to this clip, and "why I edited it this way".
    public var styleID: String?
    public var editorNotes: String?
    /// Hookable title options (with the fact check's verdicts), generated on request in Review.
    public var titleOptionsData: Data?
    public var titleOptions: [TitleOption] {
        get { titleOptionsData.flatMap { try? JSONDecoder().decode([TitleOption].self, from: $0) } ?? [] }
        set { titleOptionsData = try? JSONEncoder().encode(newValue) }
    }

    public init(_ h: Highlight, style: CaptionStyle) {
        id = h.id; start = h.start; end = h.end; title = h.title; hook = h.hook
        tags = h.tags; score = h.score; finalScore = h.finalScore; reason = h.reason
        coreStart = h.coreStart; coreEnd = h.coreEnd
        signalsData = h.signals.isEmpty ? nil : try? JSONEncoder().encode(h.signals)
        // Stage B puts hashtags at the end of the description; keep them as their own editable field.
        let tagPattern = /#[\p{L}\p{N}_]+/
        hashtags = h.description.matches(of: tagPattern).map { String($0.output) }
        descriptionText = h.description.replacing(tagPattern, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        statusRaw = ClipStatus.rendering.rawValue; captionStyleRaw = style.rawValue; createdAt = .now
    }

    public var framing: Framing {
        get { Framing(raw: framingRaw) }
        set { framingRaw = newValue.raw }
    }
    public var voiceover: VoiceoverConfig {
        get { voiceoverData.flatMap { try? JSONDecoder().decode(VoiceoverConfig.self, from: $0) } ?? VoiceoverConfig() }
        set { voiceoverData = try? JSONEncoder().encode(newValue) }
    }
    public var voiceTrack: VoiceoverTrack? {
        get { voiceTrackData.flatMap { try? JSONDecoder().decode(VoiceoverTrack.self, from: $0) } }
        set { voiceTrackData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    /// The voiceover that goes into renders: enabled, generated, and generated from the current settings.
    public var activeVoiceTrack: VoiceoverTrack? {
        guard voiceover.enabled, let t = voiceTrack, t.config == voiceover else { return nil }
        return t
    }
    public var signals: [String: Int] {
        signalsData.flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
    }

    public var failure: ClipFailure? {
        get { failureRaw.flatMap(ClipFailure.init(rawValue:)) }
        set { failureRaw = newValue?.rawValue }
    }
    /// The range that must stay in the clip.
    public var keep: ClosedRange<Double> { coreEnd > coreStart ? coreStart...coreEnd : start...end }
    public var captionWords: [Word]? {
        get { captionWordsData.flatMap { try? JSONDecoder().decode([Word].self, from: $0) } }
        set { captionWordsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    /// Description + hashtags as they go to the platform.
    public var fullDescription: String {
        let tagsLine = hashtags.map { $0.hasPrefix("#") ? $0 : "#" + $0 }.joined(separator: " ")
        return [descriptionText, tagsLine].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public var status: ClipStatus {
        get { ClipStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }
    public var captionStyle: CaptionStyle {
        get { CaptionStyle(rawValue: captionStyleRaw) ?? .pop }
        set { captionStyleRaw = newValue.rawValue }
    }
    public var videoURL: URL? { videoPath.map(URL.init(fileURLWithPath:)) }
    public var effectiveScore: Int { finalScore ?? score }
}

@Model public final class PublishLogEntry {
    public var date: Date
    public var clipID: UUID
    public var sourceTitle: String
    public var title: String
    public var videoID: String?
    public var requestedPrivacy: String
    public var returnedPrivacy: String?
    public var result: String
    /// How the right to publish was established (owner match / explicit permission + date).
    public var rightsBasis: String

    public init(clipID: UUID, sourceTitle: String, title: String, requestedPrivacy: String, result: String, rightsBasis: String) {
        date = .now; self.clipID = clipID; self.sourceTitle = sourceTitle; self.title = title
        self.requestedPrivacy = requestedPrivacy; self.result = result; self.rightsBasis = rightsBasis
    }
}

public enum Store {
    @MainActor public static func container(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([Source.self, ClipRecord.self, PublishLogEntry.self, StoryJob.self])
        let config = inMemory ? ModelConfiguration(isStoredInMemoryOnly: true)
            : ModelConfiguration(url: url ?? Paths.support.appendingPathComponent("ClipForge.store"))
        return try ModelContainer(for: schema, configurations: config)
    }
}
