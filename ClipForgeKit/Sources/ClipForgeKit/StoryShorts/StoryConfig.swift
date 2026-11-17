import Foundation

// Everything tweakable about Story Shorts lives here: options, limits, layout, mix levels and prompts.

public enum StoryTone: String, Codable, Sendable, CaseIterable, Identifiable {
    case epic, funny, hype, chill
    public var id: String { rawValue }
}

public enum StoryCropMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Smart crop when the action has a clear centre, blurred-background fill otherwise.
    case auto, smart, blur
    public var id: String { rawValue }
}

/// Edit styles. `.story` is the original Story Shorts arc; the others are Highlight Remix modes.
public enum RemixStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case story, montage, countdown, funny, recap
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .story: "Story (hook → climax → payoff)"
        case .montage: "Montage (fast, beat-synced)"
        case .countdown: "Best-of countdown"
        case .funny: "Funny moments"
        case .recap: "Recap (chronological)"
        }
    }
    /// Allowed segment length (source seconds).
    var segment: ClosedRange<Double> {
        switch self {
        case .story: 1...12
        case .montage: 1.2...4
        case .countdown: 2.5...7
        case .funny: 2...7
        case .recap: 2...6
        }
    }
    var isRemix: Bool { self != .story }
}

public enum OutputFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case vertical, landscape, square
    public var id: String { rawValue }
    public var label: String { ["vertical": "9:16 Shorts/Reels", "landscape": "16:9", "square": "1:1"][rawValue]! }
    public var size: (w: Int, h: Int) { self == .vertical ? (1080, 1920) : self == .landscape ? (1920, 1080) : (1080, 1080) }
    var aspect: Double { Double(size.w) / Double(size.h) }
    var canvas: CGSize { CGSize(width: size.w, height: size.h) }
}

public struct StoryOptions: Codable, Sendable, Equatable {
    public var gameName = ""
    public var targetSeconds: Double = StoryConfig.defaultLength
    public var tone: StoryTone = .epic
    public var captionStyle: CaptionStyle = .pop
    /// Word-by-word speech subtitles (layer b). Narrative text (layer a) is always on.
    public var subtitles = true
    public var cropMode: StoryCropMode = .auto
    public var style: RemixStyle = .story
    public var format: OutputFormat = .vertical
    /// Optional direction from the user, e.g. "only clutch moments".
    public var prompt = ""
    /// Pro Editor style profile id (nil = Auto) and intensity (0 subtle … 1 aggressive).
    public var styleID: String?
    public var intensity = 0.5
    public init() {}

    enum CodingKeys: String, CodingKey { case gameName, targetSeconds, tone, captionStyle, subtitles, cropMode, style, format, prompt, styleID, intensity }
    /// Tolerant decoding so options saved before new fields existed still load.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        gameName = try c.decodeIfPresent(String.self, forKey: .gameName) ?? ""
        targetSeconds = try c.decodeIfPresent(Double.self, forKey: .targetSeconds) ?? StoryConfig.defaultLength
        tone = try c.decodeIfPresent(StoryTone.self, forKey: .tone) ?? .epic
        captionStyle = try c.decodeIfPresent(CaptionStyle.self, forKey: .captionStyle) ?? .pop
        subtitles = try c.decodeIfPresent(Bool.self, forKey: .subtitles) ?? true
        cropMode = try c.decodeIfPresent(StoryCropMode.self, forKey: .cropMode) ?? .auto
        style = try c.decodeIfPresent(RemixStyle.self, forKey: .style) ?? .story
        format = try c.decodeIfPresent(OutputFormat.self, forKey: .format) ?? .vertical
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        styleID = try c.decodeIfPresent(String.self, forKey: .styleID)
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 0.5
    }
}

public enum StoryConfig {
    // Options
    public static let lengths: [Double] = [15, 30, 60, 90]
    public static let defaultLength: Double = 30
    public static let videoTypes = ["mp4", "mov", "mkv", "m4v"]

    // Models (vision-capable). Uses the shared Anthropic key and CostTracker.
    public static let model = "claude-sonnet-5-5"
    public static let effort = "medium"
    public static let maxTokens = 6000

    // Analysis
    static let proxyFPS = 5.0
    static let maxCandidates = 8
    // Remix: more, shorter candidates spread over the whole timeline.
    static let remixCandidates = 20
    static let remixBuckets = 10           // timeline slices that each contribute their best moment first
    static let remixFramesPerMoment = 2
    static let candidateSeconds = 12.0          // window around each peak offered to the model
    static let framesPerMoment = 3
    static let frameWidth = 512
    /// Signal weights for picking candidate moments (z-scored per video).
    static let weights = (loudness: 0.35, motion: 0.30, scene: 0.15, speech: 0.20)

    // Story
    static let minBeatSeconds = 1.0
    static let lengthTolerance = 0.05            // final length is trimmed/extended to within ± this share of the target

    // Render
    static let crossfade = 0.25
    static let fps = 30
    static let videoBitrate = "8M"
    /// Smart crop is used when ≥ this share of sampled frames had a detectable subject…
    static let smartCropMinHits = 0.5
    /// …and the subject's horizontal spread (std dev of centre, 0–1) is below this.
    static let smartCropMaxSpread = 0.22

    // Captions — 9:16 safe zone (1080×1920 canvas). Bottom 20% and right edge hold platform UI.
    static let safeLeft = 70.0
    static let safeRight = 150.0
    static let subtitleBottom = 0.30              // subtitle block's bottom edge, fraction from the canvas bottom
    static let narrativeTop = 0.86                // narrative block's top edge, fraction from the canvas bottom

    // Music
    nonisolated(unsafe) static var musicRootOverride: URL?  // tests only
    public static var musicRoot: URL {
        musicRootOverride ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipForge")
    }
    static let musicVolume = 0.30                 // linear gain under game audio
    static let duckedVolume = 0.10                // while someone speaks / important game audio
    static let musicFadeIn = 0.5
    static let musicFadeOut = 1.5
    static let beatSnap = 0.25                    // max cut nudge to land on a beat, seconds
    static let montageBeatSnap = 0.5              // montage cuts follow the beat more strictly

    // Stage timeouts (seconds). Every stage ends in done or failed; none can spin forever.
    static let timeouts: [StoryStage: Double] = [
        .importing: 120, .analyzing: 3600, .writing: 600, .captioning: 300, .music: 300, .rendering: 1800,
    ]

    // MARK: Prompts

    static let system = """
    You are a short-form video editor who turns raw gameplay into a vertical story short (YouTube Shorts, Reels, TikTok).

    You receive: the game name (if known), the target length and tone, a transcript of any commentary with timestamps, and a numbered list of candidate moments. Each candidate has a time window in seconds on the source video, its signal strengths (loudness, motion, scene changes, speech), and a few frames from inside the window. Look at the frames to understand what is actually happening: kills, wins, fails, clutch plays, chaos, reactions, menus or loading screens (avoid those).

    Build a story arc from these moments, in this order:
    1. hook — 1–3 s. The single most attention-grabbing instant. It must make sense with zero context and make a viewer stay. Prefer visible action or emotion (gunfire, an explosion, a kill, a near-death, a wild reaction) over menus, maps, objective markers or calm walking.
    2. buildup — tension: the setup, the risk, the chase, the near-miss.
    3. climax — the peak moment: the play, the win, the disaster.
    4. payoff — the ending: the reaction, the result, the punchline. End on something satisfying or funny, not mid-action.
    You may use 2–3 buildup beats if the target length needs it. You may reuse a moment for the hook that appears again later (a flash-forward), which is a classic short-form technique.

    Rules:
    - Every beat's start/end must lie inside one candidate window. Beats must not overlap each other in source time unless the hook is a flash-forward.
    - Total length of all beats should be within ±10% of the target length.
    - Each beat gets a short on-screen caption (max 6 words, punchy, story-driven, matching the tone; no hashtags, no emojis unless the tone is funny). The caption tells the story the footage can't: stakes, context, irony.
    - Set "important_audio": true on beats where the game sound or voice is essential (a voice line, an explosion, a victory sound), so the music ducks under it.
    - Only describe what the frames and transcript support. Do not invent events.
    - mood must be one of: epic, funny, hype, chill (usually the requested tone).
    - title: max 70 characters, curiosity-driven but accurate. description: 1–2 sentences. hashtags: 4–8, each starting with #, include #Shorts and the game if known.

    Output ONLY this JSON object (no prose, no code fences):
    {"mood": "epic", "title": "...", "description": "...", "hashtags": ["#Shorts", "..."],
     "beats": [{"purpose": "hook", "start": 12.0, "end": 14.5, "caption": "...", "important_audio": false}, ...]}
    """

    static func userIntro(_ o: StoryOptions, duration: Double) -> String {
        """
        Game: \(o.gameName.isEmpty ? "unknown — infer from the frames if you can" : o.gameName)
        Tone: \(o.tone.rawValue)
        Style: \(o.style.rawValue)
        Target length: \(Int(o.targetSeconds)) s
        Source video length: \(Int(duration)) s
        """ + (o.prompt.isEmpty ? "" : "\nDirection from the creator (follow it): \(o.prompt)")
    }

    /// Fields every plan may use, appended to each style's prompt.
    static let editFields = """

    Optional per beat:
    - "transition" into the beat: "cut" (default for most), "fade", "flash" (white flash, for impact), "zoom" (punch-in), "whip" (fast slide). Mostly cuts; use the others sparingly where they add energy.
    - "speed": 1 normally, 0.5 for a slow-motion peak (at most 1–2 beats).
    """

    static func system(for style: RemixStyle) -> String {
        style == .story ? system + editFields : remixSystem(style) + editFields
    }

    static func remixSystem(_ style: RemixStyle) -> String {
        let order: String
        switch style {
        case .story: order = ""
        case .montage: order = "Montage: fast, energetic, beat-driven. Build intensity toward a climax, end on the strongest payoff or a loop-friendly moment. Mostly very short beats."
        case .countdown: order = "Best-of countdown: after the hook, present the moments from weakest to strongest. Captions number them (\"#5 …\", \"#4 …\" … \"#1 …\"). The last beat is #1."
        case .funny: order = "Funny moments: fails, glitches, absurd situations, reactions. Order for comedic rhythm; end on the funniest beat."
        case .recap: order = "Recap: after the hook, beats in chronological order (ascending source time) to summarize what happened, ending with the outcome."
        case .story: order = ""
        }
        return """
        You are a short-form video editor making a highlight remix from a long video: moments taken from across the WHOLE video (beginning, middle and end), merged into a new, engaging edit.

        You receive the game/context, target length, style, an optional creator direction, the commentary transcript and numbered candidate moments spread over the timeline, each with its time window, signal strengths and frames.

        \(order)

        Rules:
        - Beat 1 is the hook (1–2 s): the most striking moment or a teaser of the climax. It may reuse a moment that appears later (flash-forward).
        - Use segments of \(Int(style.segment.lowerBound))–\(Int(style.segment.upperBound)) s, each containing its complete key action (don't start or end mid-action).
        - Take moments from across the timeline, not one stretch; no two beats may overlap in source time (except the hook teaser); avoid near-duplicate shots.
        - Every beat's start/end must lie inside one candidate window. Total length within ±10% of the target.
        - Each beat gets a short on-screen caption (max 6 words) that adds context or punch; purposes: "hook", "buildup", "climax", "payoff", "moment", or "countdown".
        - Set "important_audio": true where the game sound or voice is essential.
        - Only describe what the frames and transcript support.
        - mood: one of epic, funny, hype, chill. title: max 70 chars, accurate. description: 1–2 sentences. hashtags: 4–8 incl. #Shorts when vertical.

        Output ONLY this JSON object (no prose, no code fences):
        {"mood": "hype", "title": "...", "description": "...", "hashtags": ["#Shorts"],
         "beats": [{"purpose": "hook", "start": 812.0, "end": 813.8, "caption": "...", "important_audio": true, "transition": "cut", "speed": 1}, ...]}
        """
    }
}
