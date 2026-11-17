import AVFoundation
import Foundation

public struct TTSVoice: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var detail: String        // gender · accent · style / language
    public var previewURL: URL?
}

/// Text-to-speech behind one small interface so providers can be swapped.
public protocol TTSProvider: Sendable {
    func voices() async throws -> [TTSVoice]
    /// Writes audio to `url` (provider's native format) and returns word timings relative to the audio start.
    func synthesize(_ text: String, voice: VoiceSettings, to url: URL) async throws -> (duration: Double, words: [Word])
    var fileExtension: String { get }
}

// MARK: - ElevenLabs

public struct ElevenLabsTTS: TTSProvider {
    let key: @Sendable () -> String?
    let session: URLSession
    let sleep: @Sendable (Double) async throws -> Void
    public var fileExtension: String { "mp3" }
    static let model = "eleven_multilingual_v2"   // supports English (incl. Indian accents) and Hindi

    public static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 90
        return URLSession(configuration: c)
    }()

    public init(session: URLSession = ElevenLabsTTS.defaultSession,
                key: @escaping @Sendable () -> String? = { Keychain.get(Keychain.Key.elevenLabs) ?? ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] },
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.session = session; self.key = key; self.sleep = sleep
    }

    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard let k = key(), !k.isEmpty else { throw ClipForgeError("Add your ElevenLabs API key in Settings → Accounts (or pick the Apple voices).") }
        var r = URLRequest(url: URL(string: "https://api.elevenlabs.io" + path)!)
        r.httpMethod = method
        r.setValue(k, forHTTPHeaderField: "xi-api-key")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    /// Retries 429/5xx and network errors with backoff; clear messages otherwise.
    func send(_ r: URLRequest) async throws -> Data {
        var delay = 1.5
        for attempt in 0..<4 {
            do {
                let (data, resp) = try await session.data(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) { return data }
                let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["detail"]
                let msg = (detail as? [String: Any])?["message"] as? String ?? (detail as? String) ?? "HTTP \(code)"
                if (code == 429 || code >= 500), attempt < 3 { try await sleep(delay); delay *= 2; continue }
                throw ClipForgeError(code == 401 ? "ElevenLabs rejected the API key." : "ElevenLabs error: \(msg)")
            } catch let e as URLError where attempt < 3 {
                Log.ai.warning("ElevenLabs network error \(e.code.rawValue); retrying")
                try await sleep(delay); delay *= 2
            }
        }
        throw ClipForgeError("ElevenLabs didn't respond after several tries.")
    }

    public func voices() async throws -> [TTSVoice] {
        let data = try await send(try request("/v1/voices"))
        let list = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["voices"] as? [[String: Any]]) ?? []
        return list.compactMap { v in
            guard let id = v["voice_id"] as? String, let name = v["name"] as? String else { return nil }
            let l = v["labels"] as? [String: Any] ?? [:]
            let detail = ["gender", "accent", "age", "descriptive", "use_case"].compactMap { l[$0] as? String }.joined(separator: " · ")
            return TTSVoice(id: id, name: name, detail: detail, previewURL: (v["preview_url"] as? String).flatMap(URL.init(string:)))
        }
    }

    public func synthesize(_ text: String, voice: VoiceSettings, to url: URL) async throws -> (duration: Double, words: [Word]) {
        guard !voice.voiceID.isEmpty else { throw ClipForgeError("Pick an ElevenLabs voice first.") }
        let body: [String: Any] = [
            "text": text, "model_id": Self.model,
            "voice_settings": ["stability": voice.stability, "similarity_boost": 0.75, "style": voice.style,
                               "use_speaker_boost": true, "speed": min(1.2, max(0.7, voice.speed))],
        ]
        let data = try await send(try request("/v1/text-to-speech/\(voice.voiceID)/with-timestamps?output_format=mp3_44100_128", method: "POST", body: body))
        return try Self.decode(data, to: url)
    }

    /// `{audio_base64, alignment: {characters, character_start_times_seconds, character_end_times_seconds}}` → file + word timings.
    static func decode(_ data: Data, to url: URL) throws -> (duration: Double, words: [Word]) {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = o["audio_base64"] as? String, let audio = Data(base64Encoded: b64) else { throw ClipForgeError("ElevenLabs returned no audio.") }
        try audio.write(to: url)
        let a = (o["alignment"] ?? o["normalized_alignment"]) as? [String: Any] ?? [:]
        let chars = a["characters"] as? [String] ?? []
        let starts = (a["character_start_times_seconds"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        let ends = (a["character_end_times_seconds"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        var words: [Word] = [], cur = "", ws = 0.0, we = 0.0
        for i in chars.indices where i < starts.count && i < ends.count {
            if chars[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !cur.isEmpty { words.append(Word(cur, ws, we)); cur = "" }
            } else {
                if cur.isEmpty { ws = starts[i] }
                cur += chars[i]; we = ends[i]
            }
        }
        if !cur.isEmpty { words.append(Word(cur, ws, we)) }
        return (max(ends.last ?? 0, words.last?.end ?? 0), words)
    }
}

// MARK: - Apple (on-device)

public struct AppleTTS: TTSProvider {
    public init() {}
    public var fileExtension: String { "caf" }

    public func voices() async throws -> [TTSVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") || $0.language.hasPrefix("hi") }
            .sorted { ($0.language == "en-IN" || $0.language == "hi-IN" ? 0 : 1, $0.language, $0.name) < ($1.language == "en-IN" || $1.language == "hi-IN" ? 0 : 1, $1.language, $1.name) }
            .map { v in
                let lang = Locale.current.localizedString(forIdentifier: v.language) ?? v.language
                let q = v.quality == .premium ? " · premium" : v.quality == .enhanced ? " · enhanced" : ""
                return TTSVoice(id: v.identifier, name: v.name, detail: lang + q, previewURL: nil)
            }
    }

    public func synthesize(_ text: String, voice: VoiceSettings, to url: URL) async throws -> (duration: Double, words: [Word]) {
        try await AppleSpeechQueue.run { try await AppleSpeechJob(text: text, voice: voice, url: url).run() }
    }
}

/// The speech engine doesn't handle overlapping file renders reliably: run them one at a time.
@MainActor enum AppleSpeechQueue {
    static var tail: Task<Void, Never>?
    static func run<T: Sendable>(_ op: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let job = Task { @MainActor () async throws -> T in
            _ = await previous?.value
            return try await op()
        }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }
}

/// Renders an utterance to a file with word markers (macOS 14 `write(_:toBufferCallback:toMarkerCallback:)`).
/// Completion comes from the delegate's didFinish — the buffer stream has no reliable end marker
/// (on macOS 27 the last buffer has length 1, not 0) — with a hard timeout so it can never hang.
@MainActor final class AppleSpeechJob: NSObject, AVSpeechSynthesizerDelegate {
    let synth = AVSpeechSynthesizer()
    let utterance: AVSpeechUtterance
    let text: String
    let url: URL
    var file: AVAudioFile?
    var frames: AVAudioFramePosition = 0
    var rate = 22050.0, bytesPerFrame = 2.0
    var markers: [(range: NSRange, offset: Int)] = []
    var continuation: CheckedContinuation<(duration: Double, words: [Word]), Error>?
    var lastActivity = Date()

    init(text: String, voice: VoiceSettings, url: URL) throws {
        self.text = text; self.url = url
        utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voice.voiceID) ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = Float(min(1, max(0.1, Double(AVSpeechUtteranceDefaultSpeechRate) * voice.speed)))
        super.init()
        synth.delegate = self
    }

    func run() async throws -> (duration: Double, words: [Word]) {
        try await withCheckedThrowingContinuation { c in
            continuation = c
            synth.write(utterance, toBufferCallback: { [weak self] buffer in
                MainActor.assumeIsolated { self?.append(buffer) }
            }, toMarkerCallback: { [weak self] ms in
                MainActor.assumeIsolated {
                    self?.lastActivity = Date()
                    for m in ms where m.mark == .word { self?.markers.append((m.textRange, m.byteSampleOffset)) }
                }
            })
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(60))
                self?.finish(ClipForgeError("The Apple voice timed out."))
            }
        }
    }

    func append(_ buffer: AVAudioBuffer) {
        guard continuation != nil, let pcm = buffer as? AVAudioPCMBuffer else { return }
        lastActivity = Date()
        if pcm.frameLength == 0 { return finish(nil) }
        do {
            if file == nil {
                rate = pcm.format.sampleRate
                bytesPerFrame = Double(pcm.format.streamDescription.pointee.mBytesPerFrame)
                file = try AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
            }
            try file?.write(from: pcm)
            frames += AVAudioFramePosition(pcm.frameLength)
        } catch { finish(error) }
    }

    /// didFinish can arrive before the last buffer/marker callbacks under load: finish once they've been quiet for 0.25 s.
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in
            while self.continuation != nil, Date().timeIntervalSince(self.lastActivity) < 0.25 { try? await Task.sleep(for: .milliseconds(50)) }
            self.finish(nil)
        }
    }

    func finish(_ error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        file = nil   // closes the file
        if let error { return c.resume(throwing: error) }
        guard frames > 0 else { return c.resume(throwing: ClipForgeError("The Apple voice produced no audio.")) }
        let ns = text as NSString
        var words: [Word] = []
        for (i, m) in markers.enumerated() {
            let start = Double(m.offset) / bytesPerFrame / rate
            let end = i + 1 < markers.count ? Double(markers[i + 1].offset) / bytesPerFrame / rate : Double(frames) / rate
            let w = ns.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !w.isEmpty { words.append(Word(w, start, max(start + 0.05, end - 0.04))) }
        }
        // The last word markers can arrive late or not at all: spread any missing trailing words over the remaining audio.
        let duration = Double(frames) / rate
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count < tokens.count {
            let rest = Array(tokens[words.count...])
            let from = words.last.map { $0.end + 0.04 } ?? 0
            let total = Double(rest.map(\.count).reduce(0, +))
            var t = from
            for w in rest {
                let len = max(0.08, (duration - from) * Double(w.count) / max(total, 1))
                words.append(Word(w, t, min(duration, t + len - 0.03)))
                t += len
            }
        }
        c.resume(returning: (duration, words))
    }
}
