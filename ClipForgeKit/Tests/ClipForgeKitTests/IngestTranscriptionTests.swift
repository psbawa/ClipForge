import Foundation
import Testing
@testable import ClipForgeKit

@Test func nonSpeechTagsAreDropped() {
    let w = [Word("(gunshot)", 0, 1), Word("Get", 1, 1.2), Word("down!", 1.2, 1.5), Word("(speaking", 2, 2.2), Word("in", 2.2, 2.3),
             Word("foreign", 2.3, 2.6), Word("language)", 2.6, 3), Word("[music]", 3, 4), Word("♪", 4, 5), Word("Go.", 5, 5.3)]
    #expect(WhisperTranscriber.speechOnly(w).map(\.text) == ["Get", "down!", "Go."])
}

@Test func timestampedTranscriptBreaksOnSentences() {
    let w = [Word("Hello", 1, 1.4), Word("there.", 1.4, 2), Word("Next", 3, 3.5), Word("one!", 3.5, 4)]
    #expect(w.timestampedText == "[1.0] Hello there.\n[3.0] Next one!")
    #expect(w.slice(2.5, 10).map(\.text) == ["Next", "one!"])
}

/// End-to-end: synthesize speech, cut it like a live segment, transcribe with WhisperKit.
/// Opt-in (downloads a model): CLIPFORGE_INTEGRATION=1
@Test(.enabled(if: ProcessInfo.processInfo.environment["CLIPFORGE_INTEGRATION"] == "1"))
func whisperTranscribesSegmentWithOffset() async throws {
    let bin = try #require(Binaries.detect())
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let aiff = dir.appendingPathComponent("s.aiff"), ts = dir.appendingPathComponent("s.ts")
    try await Shell.run(URL(fileURLWithPath: "/usr/bin/say"), ["-o", aiff.path, "This is the best moment of the whole stream."])
    try await Shell.run(bin.ffmpeg, ["-loglevel", "error", "-f", "lavfi", "-i", "color=c=black:s=320x240:d=4", "-i", aiff.path,
                                     "-shortest", "-c:v", "libx264", "-c:a", "aac", "-f", "mpegts", ts.path])
    let t = WhisperTranscriber(ffmpeg: bin.ffmpeg)
    try await t.load(model: AppSettings().whisperModel)
    let words = try await t.transcribe(MediaSegment(url: ts, start: 100, end: 104), progress: nil)
    #expect(words.joinedText.lowercased().contains("best moment"))
    #expect(words.allSatisfy { $0.start >= 100 })
}

@Test func settingsSurviveSchemaChanges() throws {
    let d = UserDefaults(suiteName: UUID().uuidString)!
    // Old build saved only a subset (+ an unknown key from some other version).
    d.set(try JSONSerialization.data(withJSONObject: ["maxPerDay": 3, "privacyStatus": "unlisted", "removedKey": 1]), forKey: "settings.v1")
    let s = AppSettings.load(d)
    #expect(s.maxPerDay == 3 && s.privacyStatus == "unlisted")
    #expect(s.fastModel == "claude-haiku-5-5")  // new field gets its default
}
