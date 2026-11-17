import Foundation
import SwiftData
import Testing
@testable import ClipForgeKit

@Test func scriptMarkersEstimateAndLayout() {
    let lines = ScriptParser.lines("Hook line here\n[0:07] Pinned at seven\n\n  [12] Twelve  \nLast one")
    #expect(lines == [.init(text: "Hook line here", at: nil), .init(text: "Pinned at seven", at: 7), .init(text: "Twelve", at: 12), .init(text: "Last one", at: nil)])
    #expect(abs(ScriptParser.estimatedSeconds("one two three four five six seven eight nine ten eleven twelve thirteen", speed: 1) - 5) < 0.1)
    let starts = ScriptParser.layout(lines, durations: [2, 2, 2, 2], clipDuration: 20)
    #expect(starts[0] == 0.3 && starts[1] == 7 && starts[2] == 12)
    #expect(starts[3] >= 14 && starts[3] + 2 <= 20)                                   // after the pinned line, inside the clip
    // Unpinned lines spread across the clip; a pinned line never overlaps the previous one.
    let spread = ScriptParser.layout(ScriptParser.lines("a\nb\nc"), durations: [2, 2, 2], clipDuration: 20)
    #expect(spread[1] - spread[0] > 4 && spread[2] + 2 <= 20)
    let clash = ScriptParser.layout(ScriptParser.lines("long first line\n[0:01] too early"), durations: [3, 1], clipDuration: 10)
    #expect(clash[1] >= clash[0] + 3)
}

/// Shares MockHTTP's static script with PublishTests, so it lives in that serialized suite.
extension PublishTests {
    func audioJSON(_ text: String) -> String {
        var chars: [String] = [], st: [Double] = [], en: [Double] = []
        for (i, c) in text.enumerated() { chars.append(String(c)); st.append(Double(i) * 0.1); en.append(Double(i) * 0.1 + 0.1) }
        let o: [String: Any] = ["audio_base64": Data("ID3fake".utf8).base64EncodedString(),
                                "alignment": ["characters": chars, "character_start_times_seconds": st, "character_end_times_seconds": en]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }

    @Test func synthesizeDecodesWordTimingsAndRetries() async throws {
        let tts = ElevenLabsTTS(session: MockHTTP.session([(429, [:], #"{"detail":{"message":"busy"}}"#), (200, [:], audioJSON("Hi there"))]),
                                key: { "k" }, sleep: { _ in })
        var v = VoiceSettings(); v.provider = .elevenLabs; v.voiceID = "abc"; v.speed = 1.5
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp3")
        let (d, words) = try await tts.synthesize("Hi there", voice: v, to: url)
        #expect(words.map(\.text) == ["Hi", "there"] && abs(words[1].start - 0.3) < 1e-9 && abs(d - 0.8) < 1e-9)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let req = MockHTTP.seen.last!
        #expect(req.url!.path == "/v1/text-to-speech/abc/with-timestamps" && req.value(forHTTPHeaderField: "xi-api-key") == "k")
        #expect(MockHTTP.seen.count == 2)                                                     // retried the 429
    }

    @Test func badKeyAndMissingKeyGiveClearErrors() async throws {
        let bad = ElevenLabsTTS(session: MockHTTP.session([(401, [:], "{}")]), key: { "k" }, sleep: { _ in })
        await #expect(throws: ClipForgeError("ElevenLabs rejected the API key.")) { _ = try await bad.voices() }
        let none = ElevenLabsTTS(session: MockHTTP.session([]), key: { nil }, sleep: { _ in })
        await #expect(throws: ClipForgeError.self) { _ = try await none.voices() }
    }
}

/// Counts synth calls to prove the per-line cache.
final class CountingTTS: TTSProvider, @unchecked Sendable {
    var calls: [String] = []
    var fileExtension: String { "caf" }
    func voices() async throws -> [TTSVoice] { [TTSVoice(id: "v", name: "V", detail: "")] }
    func synthesize(_ text: String, voice: VoiceSettings, to url: URL) async throws -> (duration: Double, words: [Word]) {
        calls.append(text)
        try Data("x".utf8).write(to: url)
        let parts = text.split(separator: " ")
        return (Double(parts.count) * 0.4, parts.enumerated().map { Word(String($1), Double($0) * 0.4, Double($0) * 0.4 + 0.35) })
    }
}

@Test func unchangedLinesAreNeverResynthesized() async throws {
    let tts = CountingTTS()
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("vc-\(UUID())")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let svc = VoiceoverService(providers: [.apple: tts], cacheDir: cache)
    var c = VoiceoverConfig(); c.enabled = true; c.voice.voiceID = "v"; c.script = "First line here\nSecond line\n[0:15] Third"
    let t1 = try await svc.generate(c, clipDuration: 20)
    #expect(tts.calls.count == 3 && t1.lines[2].at == 15)
    #expect(t1.words.first?.start == t1.lines[0].at && t1.words.contains { $0.text == "Third" && $0.start == 15 })  // clip-relative words
    _ = try await svc.generate(c, clipDuration: 20)
    #expect(tts.calls.count == 3)                                           // all cached
    c.script = "First line here\nSecond line changed\n[0:15] Third"
    _ = try await svc.generate(c, clipDuration: 20)
    #expect(tts.calls.count == 4 && tts.calls.last == "Second line changed") // only the edited line
    _ = try await svc.generate(c, clipDuration: 20, regenerate: 0)
    #expect(tts.calls.count == 5 && tts.calls.last == "First line here")   // a new take of one line
    c.voice.speed = 1.2
    _ = try await svc.generate(c, clipDuration: 20)
    #expect(tts.calls.count == 8)                                           // new voice settings → new audio
}

@MainActor @Test func appleVoiceSynthesizesWithWordTimings() async throws {
    var v = VoiceSettings()
    v.voiceID = try await AppleTTS().voices().first { $0.detail.contains("India") || $0.name.contains("Rishi") }?.id ?? ""
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).caf")
    let (d, words) = try await AppleTTS().synthesize("Nobody expected this play to work.", voice: v, to: url)
    #expect(d > 1 && d < 6)
    #expect(words.map(\.text) == ["Nobody", "expected", "this", "play", "to", "work."])
    #expect(zip(words, words.dropFirst()).allSatisfy { $0.start < $1.start } && words.last!.end <= d + 0.05)
}

@Test func voiceMixGraph() {
    let mix = VoiceMix(lines: [(URL(fileURLWithPath: "/a.caf"), 1.5), (URL(fileURLWithPath: "/b.caf"), 6)], spans: [(1.5, 4), (6, 8)],
                       volume: 1.2, original: .duck, music: URL(fileURLWithPath: "/m.m4a"), captionWords: [], captions: .replace)
    let (g, inputs) = ClipService.voiceGraph(mix, firstInput: 2, hasOriginal: true, duration: 20)
    #expect(g.contains("[0:a]") && g.contains("between(t,1.35,4.25)") && g.contains("adelay=1500:all=1") && g.contains("adelay=6000:all=1"))
    #expect(g.contains("amix=inputs=4") && g.hasSuffix("[aout]") && g.contains("[4:a]"))
    #expect(inputs == ["-i", "/a.caf", "-i", "/b.caf", "-stream_loop", "-1", "-i", "/m.m4a"])
    var muted = mix; muted.original = .mute; muted.music = nil
    let (g2, _) = ClipService.voiceGraph(muted, firstInput: 2, hasOriginal: true, duration: 20)
    #expect(!g2.contains("[0:a]") && g2.contains("amix=inputs=2"))
}

/// Real render: synthetic clip + Apple voice line at 2 s, original muted → loud only while the voice speaks; captions follow the voice.
@MainActor @Test(.enabled(if: Binaries.detect() != nil))
func renderedVoiceoverIsInSync() async throws {
    let bin = try #require(Binaries.detect())
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let src = dir.appendingPathComponent("src.mp4")
    try await Shell.run(bin.ffmpeg, ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=8", "-f", "lavfi", "-i", "sine=f=300:d=8",
                                     "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", src.path])
    let line = dir.appendingPathComponent("line.caf")
    let (d, words) = try await AppleTTS().synthesize("This is the voiceover.", voice: VoiceSettings(), to: line)
    let mix = VoiceMix(lines: [(line, 2.0)], spans: [(2.0, 2.0 + d)], volume: 1, original: .mute, music: nil,
                       captionWords: words.map { Word($0.text, $0.start + 2, $0.end + 2) }, captions: .replace)
    let r = try await ClipService(ffmpeg: bin.ffmpeg).render(start: 0, end: 8, keep: 0...8, from: [MediaSegment(url: src, start: 0, end: 8)], words: [],
                                                             style: .pop, framing: .smart, voice: mix, look: nil, to: dir.appendingPathComponent("out"))
    #expect(r.start == 0 && r.end == 8)
    func rms(_ from: Double, _ len: Double) async throws -> Double {
        let out = try await Shell.runCapturingStderr(bin.ffmpeg, ["-hide_banner", "-ss", "\(from)", "-t", "\(len)", "-i", r.video.path, "-af", "volumedetect", "-f", "null", "-"])
        let m = out.range(of: #"mean_volume: (-?[\d.]+) dB"#, options: .regularExpression).map { String(out[$0]) } ?? "mean_volume: -91 dB"
        return Double(m.split(separator: " ")[1])!
    }
    let before = try await rms(0.2, 1.5), during = try await rms(2.2, max(0.5, d - 0.4))
    #expect(during > before + 20, "before \(before) dB, during \(during) dB")
    #expect(try String(contentsOf: r.srt, encoding: .utf8).contains("voiceover"))
}

@MainActor @Suite(.serialized) struct VoiceoverFlowTests {
    @Test func generateMixesIntoRenderAndStaleSettingsDropIt() async throws {
        useTempRoot()
        let clipper = MockClipper()
        let model = AppModel(container: try Store.container(inMemory: true), binaries: nil, llm: MockLLM([]), cost: freshTracker(),
                             ingest: MockIngest(dur: 420), transcriber: MockTranscriber(), clipper: clipper, publisher: MockPublisher(channelID: "UC_me"))
        let src = Source(url: "https://youtube.com/watch?v=x", info: SourceInfo(title: "S", channelID: "UC_me", channelName: "Me", isLive: false, duration: 420))
        src.ownershipConfirmedAt = .now
        model.context.insert(src)
        let rec = ClipRecord(Highlight(start: 100, end: 120, title: "T", hook: "", score: 80, reason: ""), style: .pop)
        rec.source = src
        model.context.insert(rec)
        await model.render(rec, words: sampleTranscript)
        #expect(await clipper.lastVoice == nil)                               // feature off → unchanged render
        var c = rec.voiceover
        c.enabled = true; c.script = "Watch this.\n[0:10] There it is."; c.original = .duck; c.captions = .replace
        rec.voiceover = c
        await model.generateVoiceover(rec)
        let mix = try #require(await clipper.lastVoice)
        #expect(mix.lines.count == 2 && mix.lines[1].at == 10 && mix.original == .duck)
        #expect(mix.captionWords.first.map { $0.start >= 100.3 } == true)     // session time = clip start + line time
        #expect(await clipper.lastKeep == 100...120)                          // no cut snapping with a voiceover
        #expect(rec.activeVoiceTrack != nil && rec.status == .ready)
        // Editing the script makes the generated track stale: renders go back to no voiceover until regenerated.
        c.script = "Different."
        rec.voiceover = c
        #expect(rec.activeVoiceTrack == nil)
        await model.setVoiceoverEnabled(rec, false)
        #expect(await clipper.lastVoice == nil)
    }
}
