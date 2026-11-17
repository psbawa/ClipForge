import Foundation

extension AppModel {
    /// The voiceover to mix into a clip's render, or nil (render exactly as without the feature).
    func voiceMix(for rec: ClipRecord) -> VoiceMix? {
        guard let t = rec.activeVoiceTrack else { return nil }
        let c = t.config
        return VoiceMix(lines: t.lines.map { (URL(fileURLWithPath: $0.audioPath), $0.at) }, spans: t.spans, volume: c.voiceVolume,
                        original: c.original, music: c.musicPath.map(URL.init(fileURLWithPath:)),
                        captionWords: t.words.map { Word($0.text, $0.start + rec.start, $0.end + rec.start) },
                        captions: c.captions)
    }

    /// Remix/story clips: the job's render is the base; a voiceover is mixed on top in one quick pass.
    func renderRemixClip(_ rec: ClipRecord) async {
        guard let job = story?.job(rec.storyJobID), let base = job.outputURL else {
            rec.status = .failed; rec.lastError = "The remix render is missing. Re-render it from the timeline."; return save()
        }
        guard let mix = voiceMix(for: rec), let ffmpeg = binaries?.ffmpeg else {
            rec.videoPath = base.path; rec.status = .ready; rec.lastError = nil; return save()
        }
        do {
            let out = job.folder.appendingPathComponent("remix-voiceover.mp4")
            try await ClipService.overlayVoice(video: base, mix: mix, duration: rec.end - rec.start, canvas: job.options.format.canvas,
                                               style: rec.captionStyle, ffmpeg: ffmpeg, out: out, work: job.folder)
            rec.videoPath = out.path
            rec.status = .ready
            rec.lastError = nil
        } catch {
            rec.status = .failed
            rec.failure = .render
            rec.lastError = "Voiceover mix failed: \(error.localizedDescription)"
        }
        save()
    }

    /// Synthesize (cached per line) and re-render the clip with the voiceover mixed in.
    /// `regenerate` = a line index for a new take of just that line.
    public func generateVoiceover(_ rec: ClipRecord, regenerate: Int? = nil) async {
        guard voiceJobs[rec.id] == nil else { return }
        let config = rec.voiceover, id = rec.id, clipDuration = rec.end - rec.start
        voiceJobs[id] = "Generating voice…"
        defer { voiceJobs[id] = nil }
        do {
            let track = try await withTimeout(seconds: 240) { [voice] in
                try await voice.generate(config, clipDuration: clipDuration, regenerate: regenerate) { p in
                    Task { @MainActor [weak self] in self?.voiceJobs[id] = "Generating voice… \(Int(p * 100))%" }
                }
            }
            if let last = track.lines.last, last.end > track.clipDuration + 0.5 {
                notify("The voiceover runs \(Int((last.end - track.clipDuration).rounded())) s past the end of the clip and will be cut off. Shorten the script or extend the clip.", .warning)
            }
            rec.voiceTrack = track
            save()
            voiceJobs[id] = "Mixing and rendering…"
            await render(rec, words: transcript(for: rec))
            if runningSourceID == nil { stage = .idle }
        } catch {
            rec.lastError = "Voiceover failed: \(error.localizedDescription)"
            save()
            notify("Voiceover failed: \(error.localizedDescription)")
        }
    }

    /// Turning the voiceover off re-renders the clip without it.
    public func setVoiceoverEnabled(_ rec: ClipRecord, _ on: Bool) async {
        var c = rec.voiceover
        c.enabled = on
        rec.voiceover = c
        save()
        if !on, rec.voiceTrack != nil { await render(rec, words: transcript(for: rec)); if runningSourceID == nil { stage = .idle } }
    }

    public func voices(_ provider: TTSProviderID) async throws -> [TTSVoice] {
        try await withTimeout(seconds: 30) { [voice] in try await voice.voices(provider) }
    }

    public func previewVoice(_ settings: VoiceSettings) async throws -> URL {
        try await withTimeout(seconds: 60) { [voice] in try await voice.preview(settings) }
    }

    /// Draft a script from the clip's transcript, frames and pick reason.
    public func generateScript(_ rec: ClipRecord, tone: ScriptTone) async throws -> String {
        let duration = rec.end - rec.start
        let budget = Int(duration * 2.3)
        var content: [LLMContent] = [.text("""
        Clip length: \(Int(duration)) s. Word budget: \(budget) words. Tone: \(tone.rawValue).
        Title: \(rec.title)
        Why it was picked: \(rec.reason.isEmpty ? "—" : rec.reason)
        What's said in the clip: \(transcript(for: rec).slice(rec.start, rec.end).joinedText.prefix(1500))
        Frames from the clip follow (in order).
        """)]
        content += await frames(of: rec).map { LLMContent.jpeg($0) }
        content.append(.text("Write the voiceover script now."))
        return try await scriptCall(VoiceoverPrompts.script, content)
    }

    public func shortenScript(_ rec: ClipRecord, script: String, speed: Double) async throws -> String {
        let budget = Int((rec.end - rec.start - 0.5) * 2.6 * speed * 0.9)
        return try await scriptCall(VoiceoverPrompts.shorten, [.text("Word budget: \(budget) words.\n\nScript:\n\(script)")])
    }

    func scriptCall(_ system: String, _ content: [LLMContent]) async throws -> String {
        guard await cost.canSpend(budget: settings.dailyBudgetUSD) else { throw HighlightError.budgetReached }
        let r = try await llm.complete(model: VoiceoverPrompts.model, system: system, content: content, maxTokens: 2000, effort: "low")
        await cost.record(r.usage, price: settings.prices[VoiceoverPrompts.model])
        await refreshCost()
        let text = r.text.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"“”")) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { throw ClipForgeError("Claude returned an empty script. Try again.") }
        return text
    }

    /// Three JPEG frames from the rendered clip (empty without ffmpeg / a render).
    func frames(of rec: ClipRecord) async -> [Data] {
        guard let ffmpeg = binaries?.ffmpeg, let v = rec.videoURL else { return [] }
        let d = rec.end - rec.start
        var out: [Data] = []
        for f in [0.2, 0.5, 0.8] {
            let jpg = FileManager.default.temporaryDirectory.appendingPathComponent("cf-frame-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: jpg) }
            try? await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-ss", String(format: "%.2f", d * f), "-i", v.path,
                                          "-frames:v", "1", "-vf", "scale=360:-2", "-q:v", "6", jpg.path])
            if let data = try? Data(contentsOf: jpg) { out.append(data) }
        }
        return out
    }
}

/// Runs `work`, failing with a clear message if it takes longer than `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await work() }
        g.addTask { try await Task.sleep(for: .seconds(seconds)); throw ClipForgeError("Timed out after \(Int(seconds)) s.") }
        let r = try await g.next()!
        g.cancelAll()
        return r
    }
}
