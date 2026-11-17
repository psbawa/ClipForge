import Foundation

public enum TTSProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    case elevenLabs, apple
    public var id: String { rawValue }
    public var name: String { self == .elevenLabs ? "ElevenLabs" : "Apple (on-device, free)" }
}

public enum ScriptTone: String, Codable, Sendable, CaseIterable, Identifiable {
    case hype, funny, storytelling, informative
    public var id: String { rawValue }
}

public enum OriginalAudioMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case keep, duck, mute
    public var id: String { rawValue }
    public var label: String { ["keep": "Keep", "duck": "Lower under voice", "mute": "Mute"][rawValue]! }
}

public enum VoiceCaptionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case off, replace, add
    public var id: String { rawValue }
    public var label: String { ["off": "Speech only", "replace": "Voiceover only", "add": "Both"][rawValue]! }
}

public struct VoiceSettings: Codable, Sendable, Equatable, Hashable {
    public var provider: TTSProviderID = .apple
    public var voiceID = ""
    public var voiceName = ""
    public var speed = 1.0          // 0.7–1.2 (ElevenLabs), 0.5–1.5 (Apple)
    public var stability = 0.5      // ElevenLabs only
    public var style = 0.0          // ElevenLabs only (expressiveness)
    public init() {}
}

/// Everything the user set up for a clip's voiceover. Persisted on the clip.
public struct VoiceoverConfig: Codable, Sendable, Equatable {
    public var enabled = false
    public var script = ""
    public var tone: ScriptTone = .hype
    public var voice = VoiceSettings()
    public var original: OriginalAudioMode = .duck
    public var musicPath: String?
    public var voiceVolume = 1.0
    public var captions: VoiceCaptionMode = .replace
    public init() {}
}

/// One synthesized line placed on the clip timeline (clip-relative seconds).
public struct VoiceLine: Codable, Sendable, Equatable {
    public var text: String
    public var at: Double
    public var duration: Double
    public var audioPath: String
    public var words: [Word]          // clip-relative, for captions
    public var cacheKey: String
    public var end: Double { at + duration }
}

/// The generated voiceover: lines + the config they were made from (to know when it's stale).
public struct VoiceoverTrack: Codable, Sendable, Equatable {
    public var lines: [VoiceLine]
    public var config: VoiceoverConfig
    public var clipDuration: Double
    public var words: [Word] { lines.flatMap(\.words) }
    public var spans: [(Double, Double)] { lines.map { ($0.at, $0.end) } }
}

/// What the renderer needs to mix a voiceover into a clip.
public struct VoiceMix: Sendable {
    public var lines: [(url: URL, at: Double)]
    public var spans: [(Double, Double)]
    public var volume: Double
    public var original: OriginalAudioMode
    public var music: URL?
    public var captionWords: [Word]   // clip-relative
    public var captions: VoiceCaptionMode
}

public enum ScriptParser {
    public struct Line: Equatable, Sendable { public var text: String; public var at: Double? }

    /// One line per row; optional leading "[m:ss]" or "[s]" marker pins a line to a moment.
    public static func lines(_ script: String) -> [Line] {
        script.split(whereSeparator: \.isNewline).compactMap { raw in
            var t = raw.trimmingCharacters(in: .whitespaces)
            var at: Double?
            if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
                let mark = t[t.index(after: t.startIndex)..<close]
                let parts = mark.split(separator: ":").compactMap { Double($0) }
                if parts.count == 2 { at = parts[0] * 60 + parts[1] } else if parts.count == 1 { at = parts[0] }
                if at != nil { t = String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespaces) }
            }
            return t.isEmpty ? nil : Line(text: t, at: at)
        }
    }

    /// Rough spoken length: ~2.6 words/s at speed 1 (≈155 wpm).
    public static func estimatedSeconds(_ script: String, speed: Double) -> Double {
        let words = lines(script).map { $0.text.split(separator: " ").count }.reduce(0, +)
        return Double(words) / (2.6 * max(speed, 0.3)) + Double(max(lines(script).count - 1, 0)) * 0.25
    }

    /// Start times for synthesized lines: pinned lines stay put (never overlapping the previous line);
    /// unpinned ones are spread evenly in the free time between their neighbours.
    public static func layout(_ lines: [Line], durations: [Double], clipDuration: Double, lead: Double = 0.3) -> [Double] {
        var starts = [Double](repeating: 0, count: lines.count)
        var i = 0, cursor = lead
        while i < lines.count {
            if let at = lines[i].at {
                starts[i] = max(at, cursor); cursor = starts[i] + durations[i] + 0.15; i += 1; continue
            }
            // A run of unpinned lines up to the next pinned one (or the clip end).
            var j = i
            while j < lines.count, lines[j].at == nil { j += 1 }
            let limit = j < lines.count ? max(lines[j].at!, cursor) : clipDuration - 0.2
            let speech = durations[i..<j].reduce(0, +)
            let gap = max(0.15, (limit - cursor - speech) / Double(j - i + (j < lines.count ? 1 : 0)))
            for k in i..<j { starts[k] = cursor; cursor += durations[k] + gap }
            cursor -= gap - 0.15
            i = j
        }
        return starts
    }
}
