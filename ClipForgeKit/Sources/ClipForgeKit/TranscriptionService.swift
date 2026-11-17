import Foundation
import WhisperKit

public protocol Transcribing: Actor {
    func load(model: String) async throws
    /// Word-level transcript of one segment, timestamps already on the session timeline.
    func transcribe(_ seg: MediaSegment, progress: (@Sendable (Double) -> Void)?) async throws -> [Word]
}

public actor WhisperTranscriber: Transcribing {
    let ffmpeg: URL
    var kit: WhisperKit?
    var loadedModel: String?

    public init(ffmpeg: URL) { self.ffmpeg = ffmpeg }

    public func load(model: String) async throws {
        guard kit == nil || loadedModel != model else { return }
        kit = try await WhisperKit(WhisperKitConfig(model: model, verbose: false, logLevel: .error, prewarm: true))
        loadedModel = model
    }

    public func transcribe(_ seg: MediaSegment, progress: (@Sendable (Double) -> Void)?) async throws -> [Word] {
        guard let kit else { throw ClipForgeError("Transcription model not loaded") }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", seg.url.path, "-vn", "-ac", "1", "-ar", "16000", "-f", "wav", wav.path])
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: wav.path)
        let total = max(Double(audio.count) / 16000, 0.1)
        // A short punctuated prompt keeps large-v3 turbo writing sentences (capitals + punctuation), which clip edges rely on.
        let stylePrompt = kit.tokenizer.map { t in t.encode(text: " " + TranscriptionConfig.stylePrompt).filter { $0 < t.specialTokens.specialTokenBegin } }
        // With silence-chunking the segment callback barely fires; WhisperKit's own Progress does — poll it so the
        // UI never sits at "Transcribing 0%".
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                let f = await self?.fraction() ?? 0
                if f > 0 { progress?(min(f, 0.99)) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { poll.cancel() }
        let results = try await kit.transcribe(
            audioArray: audio,
            // Split at silences and decode chunks in parallel: much faster on long audio, and each chunk starts fresh
            // (large-v3 turbo otherwise drifts into unpunctuated lowercase on long runs).
            decodeOptions: DecodingOptions(verbose: false, wordTimestamps: true, promptTokens: stylePrompt,
                                           concurrentWorkerCount: TranscriptionConfig.workers, chunkingStrategy: .vad),
            segmentCallback: { segs in
                if let end = segs.last?.end { progress?(min(Double(end) / total, 1)) }
            })
        progress?(1)
        return Self.words(from: results.flatMap(\.segments), offset: seg.start)
    }

    func fraction() -> Double { kit?.progress.fractionCompleted ?? 0 }

    static func words(from segments: [TranscriptionSegment], offset: Double) -> [Word] {
        assemble(segments.flatMap { $0.words ?? [] }.map { ($0.word, offset + Double($0.start), offset + Double($0.end)) })
    }

    /// Whisper marks the start of a word with a leading space; pieces without one continue the previous word
    /// ("merry" "-go" "-round" → "merry-go-round", "co" "-founders" → "co-founders"). Speaker-change dashes ("- Okay.")
    /// and special tokens are dropped, then non-speech tags.
    static func assemble(_ pieces: [(text: String, start: Double, end: Double)]) -> [Word] {
        var out: [Word] = []
        for p in pieces where !p.text.hasPrefix("<|") {
            let t = p.text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if p.text.first?.isWhitespace == false, let last = out.last, !last.text.hasSuffix("-") || t.first != "-" {
                out[out.count - 1].text += t
                out[out.count - 1].end = p.end
            } else {
                out.append(Word(t, p.start, p.end))
            }
        }
        // "- Okay." / lone "-" are speaker turns in Whisper's output, not speech.
        let cleaned = out.compactMap { w -> Word? in
            var t = w.text
            while t.hasPrefix("-"), t.count == 1 || t.dropFirst().first?.isWhitespace == true { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return t.isEmpty ? nil : Word(t, w.start, w.end)
        }
        return repunctuate(speechOnly(cleaned))
    }

    /// Some chunks come back as unpunctuated lowercase. Clip edges and captions need sentences, so inside long runs
    /// without sentence punctuation a pause ≥ 0.45 s ends a sentence and the next word is capitalized.
    static func repunctuate(_ words: [Word]) -> [Word] {
        var w = words.map { x -> Word in
            var x = x
            if x.text == "i" { x.text = "I" } else if x.text.hasPrefix("i'") { x.text = "I" + x.text.dropFirst() }
            return x
        }
        var run = 0
        for i in w.indices {
            run = w[i].endsSentence ? 0 : run + 1
            guard run >= TranscriptionConfig.unpunctuatedRun, i + 1 < w.count, w[i + 1].start - w[i].end >= TranscriptionConfig.sentencePause,
                  w[i].text.last.map({ $0.isLetter || $0.isNumber }) == true else { continue }
            w[i].text += "."
            w[i + 1].text = w[i + 1].text.prefix(1).uppercased() + w[i + 1].text.dropFirst()
            run = 0
        }
        if let f = w.first?.text, f.first?.isLowercase == true { w[0].text = f.prefix(1).uppercased() + f.dropFirst() }
        return w
    }

    /// Drops Whisper's non-speech tags — "(gunshot)", "[music]", "(speaking in foreign language)", "♪" — which may span words.
    static func speechOnly(_ words: [Word]) -> [Word] {
        var out: [Word] = [], closer: Character?
        for w in words {
            if let c = closer { if w.text.contains(c) { closer = nil }; continue }
            if let f = w.text.first, let c: Character = f == "(" ? ")" : f == "[" ? "]" : nil {
                if !w.text.dropFirst().contains(c) { closer = c }
                continue
            }
            let t = w.text.replacingOccurrences(of: "♪", with: "").trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(Word(t, w.start, w.end)) }
        }
        return out
    }
}

enum TranscriptionConfig {
    static let workers = 4
    static let unpunctuatedRun = 12        // words without . ! ? before pauses start counting as sentence ends
    static let sentencePause = 0.45
    static let stylePrompt = "Okay, so here's the plan. We're building it today, and it's going to be great!"
}
