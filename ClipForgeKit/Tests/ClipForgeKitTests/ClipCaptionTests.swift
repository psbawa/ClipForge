import Foundation
import Testing
@testable import ClipForgeKit

@Test func captionGroupsAndSRT() {
    let w = [Word("Hello", 10, 10.5), Word("there.", 10.5, 11), Word("This", 12, 12.3), Word("is", 12.3, 12.5), Word("a", 12.5, 12.6), Word("test", 12.6, 13)]
    let g = CaptionService.groups(w, clipStart: 10, clipEnd: 14)
    #expect(g.map { $0.words.map(\.text) } == [["Hello", "there."], ["This", "is", "a", "test"]])
    #expect(CaptionService.srt(w, clipStart: 10, clipEnd: 14).hasPrefix("1\n00:00:00,000 --> 00:00:01,000\nHello there.\n"))
    // A cut (overlapping times) or a long pause starts a new line.
    let cut = [Word("end", 1, 1.4), Word("of", 1.4, 1.6), Word("next", 1.5, 1.8), Word("later", 3.5, 3.9)]
    #expect(CaptionService.groups(cut, clipStart: 0, clipEnd: 5).map { $0.words.map(\.text) } == [["end", "of"], ["next"], ["later"]])
    let t = CaptionService.timeline(g, duration: 4)
    #expect(abs(t.map(\.dur).reduce(0, +) - 4) < 0.001)   // frames cover the whole clip
    #expect(t.contains { $0.group == -1 })                  // gap between groups is blank
}

@Test func cropExpressionIsPiecewiseLinear() {
    let e = Reframer.expression([0.2, 0.4, 0.6], times: [0, 1, 2])
    #expect(e == "if(lt(t,1.000),0.2000+(0.20000)*(t-0.000),if(lt(t,2.000),0.4000+(0.20000)*(t-1.000),0.6000))")
}

/// Real ffmpeg render from 3 live-style .ts segments. Runs when ffmpeg is installed.
@Test(.enabled(if: Binaries.detect() != nil))
func rendersVerticalCaptionedShortFromSegments() async throws {
    let bin = try #require(Binaries.detect())
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var segs: [MediaSegment] = []
    for i in 0..<3 {
        let u = dir.appendingPathComponent("seg_\(i).ts")
        try await Shell.run(bin.ffmpeg, ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=10",
                                         "-f", "lavfi", "-i", "sine=f=440:d=10", "-c:v", "libx264", "-c:a", "aac", "-f", "mpegts", u.path])
        segs.append(MediaSegment(url: u, start: Double(i) * 10, end: Double(i + 1) * 10))
    }
    let words = stride(from: 5.0, to: 28, by: 0.5).map { Word("word\(Int($0 * 2) % 7 == 0 ? "." : "")", $0, $0 + 0.4) }
    let clip = try await ClipService(ffmpeg: bin.ffmpeg).render(start: 5, end: 27, keep: 6...26, from: segs, words: words, style: .pop, framing: .smart, voice: nil, look: nil, to: dir.appendingPathComponent("out"))
    let probe: String
    do { try await Shell.run(bin.ffmpeg, ["-hide_banner", "-i", clip.video.path]); probe = "" } catch let e as ClipForgeError { probe = e.message }
    #expect(probe.contains("1080x1920"))
    #expect(try await IngestService.duration(of: clip.video, ffmpeg: bin.ffmpeg) > 21.5)
    #expect(FileManager.default.fileExists(atPath: clip.srt.path))
    if let snap = ProcessInfo.processInfo.environment["CLIPFORGE_SNAPSHOT"] {
        try await Shell.run(bin.ffmpeg, ["-loglevel", "error", "-y", "-ss", "3", "-i", clip.video.path, "-frames:v", "1", "-vf", "scale=360:-2", snap])
    }
}
