import CryptoKit
import Foundation

enum VoiceoverPrompts {
    static let model = "claude-sonnet-5-5"
    static let script = """
    You write voiceover scripts for vertical short-form clips (YouTube Shorts, Reels, TikTok). The voiceover plays over the clip, so it must match what's on screen and fit the time.

    You get: the clip length, a word budget, the tone, why the moment was picked, what's said in the clip, and a few frames.

    Rules:
    - Hook in the first line (max ~8 words): make the viewer stay.
    - Then 1–4 short lines that add what the footage can't: stakes, context, a punchline, a reaction. Don't describe the obvious.
    - End with a payoff or a short call to watch again / comment.
    - Stay within the word budget. Short sentences, spoken style, no emojis, no hashtags, no stage directions.
    - Match the tone: hype = energetic; funny = playful, punchy; storytelling = narrative, building tension; informative = clear, factual.
    - Only claim what the frames and transcript support.
    - If a line must land on a specific moment, prefix it with a timestamp like [0:07]; otherwise no marker.

    Output ONLY the script: one line per spoken line. No quotes, no headings, no commentary.
    """
    static let shorten = """
    Shorten this voiceover script so it can be spoken within the word budget. Keep the hook and the payoff, keep any [m:ss] markers on the lines you keep, keep the tone. Output ONLY the script, one line per spoken line.
    """
}

/// Synthesis with a per-line cache, line layout and word timings for captions.
public actor VoiceoverService {
    let providers: [TTSProviderID: any TTSProvider]
    let cacheDir: URL

    public init(providers: [TTSProviderID: any TTSProvider] = [.elevenLabs: ElevenLabsTTS(), .apple: AppleTTS()],
                cacheDir: URL? = nil) {
        self.providers = providers
        self.cacheDir = cacheDir ?? Paths.dir("voice-cache")
    }

    func provider(_ id: TTSProviderID) throws -> any TTSProvider {
        guard let p = providers[id] else { throw ClipForgeError("\(id.name) isn't available.") }
        return p
    }

    public func voices(_ id: TTSProviderID) async throws -> [TTSVoice] { try await provider(id).voices() }

    /// Same text + voice + settings → same audio. Unchanged lines are never paid for twice.
    static func cacheKey(_ text: String, _ v: VoiceSettings) -> String {
        let s = [v.provider.rawValue, v.voiceID, String(format: "%.2f|%.2f|%.2f", v.speed, v.stability, v.style), text].joined(separator: "|")
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    struct Cached: Codable { var duration: Double; var words: [Word]; var file: String }

    func line(_ text: String, voice: VoiceSettings, fresh: Bool) async throws -> (url: URL, Cached) {
        let p = try provider(voice.provider)
        let key = Self.cacheKey(text, voice)
        let meta = cacheDir.appendingPathComponent(key + ".json")
        if !fresh, let d = try? Data(contentsOf: meta), let c = try? JSONDecoder().decode(Cached.self, from: d),
           FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent(c.file).path) {
            return (cacheDir.appendingPathComponent(c.file), c)
        }
        let file = key + (fresh ? "-\(UUID().uuidString.prefix(6))" : "") + "." + p.fileExtension
        let url = cacheDir.appendingPathComponent(file)
        let (duration, words) = try await p.synthesize(text, voice: voice, to: url)
        let c = Cached(duration: duration, words: words, file: file)
        try JSONEncoder().encode(c).write(to: meta)   // a fresh take becomes the cached one
        return (url, c)
    }

    /// Synthesizes every line (cached), places them on the clip and returns the track.
    /// `regenerate` re-synthesizes just that line index (a new take); `nil` reuses the cache.
    public func generate(_ config: VoiceoverConfig, clipDuration: Double, regenerate: Int? = nil,
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> VoiceoverTrack {
        let parsed = ScriptParser.lines(config.script)
        guard !parsed.isEmpty else { throw ClipForgeError("Write or generate a script first.") }
        var made: [(URL, Cached)] = []
        for (i, l) in parsed.enumerated() {
            try Task.checkCancellation()
            do { made.append(try await line(l.text, voice: config.voice, fresh: i == regenerate)) } catch {
                throw ClipForgeError("Line \(i + 1) (“\(l.text.prefix(40))”): \(error.localizedDescription)")
            }
            progress(Double(i + 1) / Double(parsed.count))
        }
        let starts = ScriptParser.layout(parsed, durations: made.map(\.1.duration), clipDuration: clipDuration)
        let lines = parsed.indices.map { i in
            VoiceLine(text: parsed[i].text, at: starts[i], duration: made[i].1.duration, audioPath: made[i].0.path,
                      words: made[i].1.words.map { Word($0.text, $0.start + starts[i], $0.end + starts[i]) },
                      cacheKey: Self.cacheKey(parsed[i].text, config.voice))
        }
        return VoiceoverTrack(lines: lines, config: config, clipDuration: clipDuration)
    }

    /// Short sample for the "Preview voice" button (cached like any line).
    public func preview(_ voice: VoiceSettings) async throws -> URL {
        let sample = voice.voiceName.isEmpty ? "This is how your voiceover will sound." : "Hi, I'm \(voice.voiceName). This is how your voiceover will sound."
        return try await line(sample, voice: voice, fresh: false).url
    }
}
