import AVFoundation
import SwiftUI

/// Optional per-clip voiceover in the review screen. Off by default; nothing changes for clips without it.
struct VoiceoverSection: View {
    @Bindable var model: AppModel
    @Bindable var clip: ClipRecord
    @State var config = VoiceoverConfig()
    @State var voices: [TTSVoice] = []
    @State var voicesError: String?
    @State var busy: String?
    @State var error: String?
    @State var player: AVAudioPlayer?
    @State var loaded = false

    var duration: Double { clip.end - clip.start }
    var estimate: Double { ScriptParser.estimatedSeconds(config.script, speed: config.voice.speed) }
    var job: String? { model.voiceJobs[clip.id] }
    var stale: Bool { config.enabled && clip.activeVoiceTrack == nil }

    var body: some View {
        Section("Voiceover") {
            Toggle("Add voiceover", isOn: Binding(get: { config.enabled }, set: { on in
                config.enabled = on
                Task { await model.setVoiceoverEnabled(clip, on) }
            }))
            if config.enabled { editor }
        }
        .onAppear {
            config = clip.voiceover
            if config.voice.voiceID.isEmpty, Keychain.get(Keychain.Key.elevenLabs) != nil { config.voice.provider = .elevenLabs }
            loaded = true
        }
        .onChange(of: config) { if loaded, config != clip.voiceover { clip.voiceover = config; model.save() } }
        .task(id: config.voice.provider) { await loadVoices() }
    }

    @ViewBuilder var editor: some View {
        // Script
        HStack {
            Picker("Tone", selection: $config.tone) { ForEach(ScriptTone.allCases) { Text($0.rawValue.capitalized).tag($0) } }.frame(width: 200)
            Spacer()
            Button(busy == "script" ? "Writing…" : "Generate script with AI") { run("script") { config.script = try await model.generateScript(clip, tone: config.tone) } }
                .disabled(busy != nil)
        }
        TextEditor(text: $config.script).frame(height: 96).themeFont(.body)
            .overlay(alignment: .topLeading) {
                if config.script.isEmpty { Text("Write a script, one spoken line per row. Start a line with [0:05] to pin it to a moment.").foregroundStyle(.themeMuted).padding(6).allowsHitTesting(false) }
            }
        HStack {
            let tooLong = estimate > duration - 0.3
            Text("≈ \(Int(estimate.rounded())) s spoken · clip \(Int(duration.rounded())) s")
                .themeFont(.caption).foregroundStyle(tooLong ? .themeDanger : .themeMuted)
            if tooLong {
                Text("Too long for the clip").themeFont(.caption, weight: .bold).foregroundStyle(.themeDanger)
                Button(busy == "shorten" ? "Shortening…" : "Shorten with AI") {
                    run("shorten") { config.script = try await model.shortenScript(clip, script: config.script, speed: config.voice.speed) }
                }.controlSize(.small).disabled(busy != nil)
            }
        }
        // Voice
        Picker("Provider", selection: $config.voice.provider) { ForEach(TTSProviderID.allCases) { Text($0.name).tag($0) } }
        HStack {
            Picker("Voice", selection: Binding(get: { config.voice.voiceID }, set: { id in
                config.voice.voiceID = id
                config.voice.voiceName = voices.first { $0.id == id }?.name ?? ""
            })) {
                if voices.isEmpty { Text(voicesError == nil ? "Loading…" : "Unavailable").tag(config.voice.voiceID) }
                ForEach(voices) { v in Text(v.detail.isEmpty ? v.name : "\(v.name) — \(v.detail)").tag(v.id) }
            }
            Button(busy == "preview" ? "…" : "Preview voice") { run("preview") { try await play(try await model.previewVoice(config.voice)) } }
                .disabled(busy != nil || config.voice.voiceID.isEmpty)
        }
        if let voicesError { Text(voicesError).themeFont(.caption).foregroundStyle(.themeDanger) }
        let el = config.voice.provider == .elevenLabs
        LabeledSlider(label: "Speed", value: $config.voice.speed, range: el ? 0.7...1.2 : 0.5...1.5, format: "%.2f×")
        if el {
            LabeledSlider(label: "Stability", value: $config.voice.stability, range: 0...1, format: "%.2f")
            LabeledSlider(label: "Emotion / style", value: $config.voice.style, range: 0...1, format: "%.2f")
        }
        // Mix
        Picker("Original audio", selection: $config.original) { ForEach(OriginalAudioMode.allCases) { Text($0.label).tag($0) } }
        Picker("Background music", selection: Binding(get: { config.musicPath ?? "" }, set: { config.musicPath = $0.isEmpty ? nil : $0 })) {
            Text("None").tag("")
            ForEach(MusicLibrary.tracks()) { Text($0.name).tag($0.path) }
        }
        LabeledSlider(label: "Voice volume", value: $config.voiceVolume, range: 0.3...2, format: "%.1f×")
        Picker("Captions", selection: $config.captions) { ForEach(VoiceCaptionMode.allCases) { Text($0.label).tag($0) } }
        // Generate
        HStack {
            Button(job ?? (clip.voiceTrack == nil ? "Generate voiceover" : "Regenerate & render")) { Task { await model.generateVoiceover(clip) } }
                .buttonStyle(.themedPrimary)
                .disabled(job != nil || config.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || config.voice.voiceID.isEmpty)
            if job != nil { ProgressView().controlSize(.small) }
        }
        if stale, clip.voiceTrack != nil, job == nil {
            Text("Settings changed since the last voiceover — generate again to apply them.").themeFont(.caption).foregroundStyle(.themeWarning)
        }
        if let error { Text(error).themeFont(.caption).foregroundStyle(.themeDanger).textSelection(.enabled) }
        if let t = clip.voiceTrack, !stale {
            ForEach(Array(t.lines.enumerated()), id: \.offset) { i, l in
                HStack {
                    Text(String(format: "%.1fs", l.at)).themeFont(.caption, digits: true).foregroundStyle(.themeMuted).frame(width: 40, alignment: .leading)
                    Text(l.text).lineLimit(2)
                    Spacer()
                    Button { Task { await model.generateVoiceover(clip, regenerate: i) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("New take of this line").disabled(job != nil)
                }
            }
        }
    }

    func loadVoices() async {
        voices = []; voicesError = nil
        do {
            voices = try await model.voices(config.voice.provider)
            if !voices.contains(where: { $0.id == config.voice.voiceID }), let first = voices.first {
                config.voice.voiceID = first.id; config.voice.voiceName = first.name
            }
        } catch { voicesError = error.localizedDescription }
    }

    func play(_ url: URL) throws {
        player?.stop()
        player = try AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    func run(_ name: String, _ work: @escaping @MainActor () async throws -> Void) {
        busy = name; error = nil
        Task { @MainActor in
            do { try await work() } catch { self.error = error.localizedDescription }
            busy = nil
        }
    }
}

struct LabeledSlider: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: String
    var body: some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value)).themeFont(.caption, digits: true).frame(width: 48, alignment: .trailing)
        }
    }
}
