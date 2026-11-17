import Foundation

/// Everything selection needs from the pixels and audio, from ONE decode of the video: per-second signals, a 1 fps
/// frame folder (text scan, the whole-video watch pass, triage/rating frames) and a 16 kHz mono WAV (sound events).
/// Before this, the video was decoded three times plus ~160 single-frame seeks.
struct VideoScan: Sendable {
    var signals: StorySignals
    var frames: URL?            // f00000.jpg = second 0, f00001.jpg = second 1, …
    var wav: URL?
    var duration: Double

    /// Frame for second `t` (clamped to what exists).
    func frame(at t: Double) -> URL? {
        guard let frames else { return nil }
        let n = max(0, min(Int(duration.rounded(.down)), Int(t)))
        for k in [n, n - 1, n + 1] where k >= 0 {
            let f = frames.appendingPathComponent(String(format: "f%05d.jpg", k))
            if FileManager.default.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    func frames(from a: Double, to b: Double, count: Int) -> [String] {
        (0..<count).compactMap { j in frame(at: a + (b - a) * Double(j + 1) / Double(count + 1))?.path }
    }
}

enum VideoScanner {
    static let frameWidth = 640

    static func run(_ video: URL, duration: Double, hasAudio: Bool, ffmpeg: URL, work: URL,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> VideoScan {
        let dir = work.appendingPathComponent("scan")
        let frames = dir.appendingPathComponent("frames"), done = dir.appendingPathComponent("done")
        let v = dir.appendingPathComponent("video-signals.txt"), a = dir.appendingPathComponent("audio-signals.txt"), wav = dir.appendingPathComponent("audio16k.wav")
        if !FileManager.default.fileExists(atPath: done.path) {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            var graph = "[0:v]split=2[s1][s2];[s1]fps=\(StoryConfig.proxyFPS),scale=320:-2,scdet=threshold=100,metadata=mode=print:file='\(StoryAnalyzer.esc(v.path))'[vo];"
                + "[s2]fps=1,scale=\(frameWidth):-2[fr]"
            var outs = ["-map", "[vo]", "-f", "null", "/dev/null", "-map", "[fr]", "-q:v", "5", "-start_number", "0", frames.appendingPathComponent("f%05d.jpg").path]
            if hasAudio {
                graph += ";[0:a]asplit=2[a1][a2];[a1]ebur128=metadata=1,ametadata=mode=print:file='\(StoryAnalyzer.esc(a.path))'[ao];"
                    + "[a2]aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono[w]"
                outs += ["-map", "[ao]", "-f", "null", "/dev/null", "-map", "[w]", wav.path]
            }
            // Software decode: measured 2.3× faster than -hwaccel videotoolbox here (frames are copied back for filtering).
            let watcher = Task {
                while !Task.isCancelled {
                    let n = (try? FileManager.default.contentsOfDirectory(atPath: frames.path).count) ?? 0
                    progress(min(0.99, Double(n) / max(duration, 1)))
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            defer { watcher.cancel() }
            try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", video.path, "-filter_complex", graph] + outs)
            try "ok".write(to: done, atomically: true, encoding: .utf8)
        }
        progress(1)
        let n = max(1, Int(duration.rounded(.up)))
        let vs = StoryAnalyzer.parse((try? String(contentsOf: v, encoding: .utf8)) ?? "", keys: ["lavfi.scd.mafd", "lavfi.scd.score"])
        let au = hasAudio ? StoryAnalyzer.parse((try? String(contentsOf: a, encoding: .utf8)) ?? "", keys: ["lavfi.r128.M"]) : [:]
        let sig = StorySignals(loudness: StoryAnalyzer.perSecond(au["lavfi.r128.M"] ?? [], n, max, empty: -70).map { max($0, -70) },
                               motion: StoryAnalyzer.perSecond(vs["lavfi.scd.mafd"] ?? [], n, { ($0 + $1) / 2 }, empty: 0),
                               scene: StoryAnalyzer.perSecond(vs["lavfi.scd.score"] ?? [], n, max, empty: 0))
        return VideoScan(signals: sig, frames: frames, wav: hasAudio && FileManager.default.fileExists(atPath: wav.path) ? wav : nil, duration: duration)
    }
}
