import Foundation

/// A stretch of source video worth showing to the model, with its signal strengths (0–100, relative to this video).
public struct StoryMoment: Codable, Sendable, Hashable {
    public var index: Int
    public var start: Double
    public var end: Double
    public var loudness: Int
    public var motion: Int
    public var scene: Int
    public var speech: Int
    public var frames: [String] = []

    func contains(_ s: Double, _ e: Double, slack: Double = 0.5) -> Bool { s >= start - slack && e <= end + slack }
}

/// Per-second signal series for a video.
struct StorySignals: Sendable {
    var loudness: [Double]  // momentary LUFS (max per second)
    var motion: [Double]    // mean absolute frame difference (avg per second)
    var scene: [Double]     // scene-change score (max per second)
}

enum StoryAnalyzer {
    /// Duration and whether there's an audio stream, from `ffmpeg -i` (which exits non-zero by design).
    static func probe(_ video: URL, ffmpeg: URL) async throws -> (duration: Double, hasAudio: Bool) {
        var info = ""
        do { try await Shell.run(ffmpeg, ["-hide_banner", "-i", video.path]) } catch let e as ClipForgeError { info = e.message }
        guard let r = info.range(of: #"Duration: (\d+):(\d+):(\d+\.?\d*)"#, options: .regularExpression) else {
            throw ClipForgeError("Couldn't read this video. Is it a valid mp4/mov/mkv file?")
        }
        let p = info[r].dropFirst(10).split(separator: ":").compactMap { Double($0) }
        guard p.count == 3, !info.contains("Video: none") else { throw ClipForgeError("Couldn't read this video's duration.") }
        return (p[0] * 3600 + p[1] * 60 + p[2], info.contains("Audio:"))
    }

    /// One decode pass on a 5 fps, 320 px proxy: scene/motion from `scdet`, loudness from `ebur128`.
    static func signals(_ video: URL, duration: Double, hasAudio: Bool, ffmpeg: URL, work: URL) async throws -> StorySignals {
        let v = work.appendingPathComponent("video-signals.txt"), a = work.appendingPathComponent("audio-signals.txt")
        var graph = "[0:v]fps=\(StoryConfig.proxyFPS),scale=320:-2,scdet=threshold=100,metadata=mode=print:file='\(esc(v.path))'[vo]"
        var maps = ["-map", "[vo]"]
        if hasAudio {
            graph += ";[0:a]ebur128=metadata=1,ametadata=mode=print:file='\(esc(a.path))'[ao]"
            maps += ["-map", "[ao]"]
        }
        try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-i", video.path,
                                     "-filter_complex", graph] + maps + ["-f", "null", "-"])
        let n = max(1, Int(duration.rounded(.up)))
        let vs = parse((try? String(contentsOf: v, encoding: .utf8)) ?? "", keys: ["lavfi.scd.mafd", "lavfi.scd.score"])
        let au = hasAudio ? parse((try? String(contentsOf: a, encoding: .utf8)) ?? "", keys: ["lavfi.r128.M"]) : [:]
        return StorySignals(loudness: perSecond(au["lavfi.r128.M"] ?? [], n, max, empty: -70).map { max($0, -70) },
                            motion: perSecond(vs["lavfi.scd.mafd"] ?? [], n, { ($0 + $1) / 2 }, empty: 0),
                            scene: perSecond(vs["lavfi.scd.score"] ?? [], n, max, empty: 0))
    }

    static func esc(_ p: String) -> String { p.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:").replacingOccurrences(of: "'", with: "\\'") }

    /// `metadata=print` output → key → [(time, value)].
    static func parse(_ text: String, keys: Set<String>) -> [String: [(Double, Double)]] {
        var out: [String: [(Double, Double)]] = [:], t = 0.0
        for line in text.split(separator: "\n") {
            if let r = line.range(of: "pts_time:") {
                t = Double(line[r.upperBound...].prefix { !$0.isWhitespace }) ?? t
            } else if let eq = line.firstIndex(of: "=") {
                let k = String(line[..<eq])
                if keys.contains(k), let v = Double(line[line.index(after: eq)...]), v.isFinite { out[k, default: []].append((t, v)) }
            }
        }
        return out
    }

    static func perSecond(_ samples: [(Double, Double)], _ n: Int, _ combine: (Double, Double) -> Double, empty: Double) -> [Double] {
        var out = [Double?](repeating: nil, count: n)
        for (t, v) in samples where t >= 0 { let i = min(n - 1, Int(t)); out[i] = out[i].map { combine($0, v) } ?? v }
        return out.map { $0 ?? empty }
    }

    /// Picks the strongest non-overlapping moments. Pure, so it's unit-tested.
    static func candidates(_ s: StorySignals, words: [Word], duration: Double,
                           count: Int = StoryConfig.maxCandidates, window: Double = StoryConfig.candidateSeconds,
                           buckets: Int = 0) -> [StoryMoment] {
        let n = s.motion.count
        guard n > 0 else { return [] }
        if duration <= window * 1.5 {
            return [StoryMoment(index: 1, start: 0, end: duration, loudness: 50, motion: 50, scene: 50, speech: words.isEmpty ? 0 : 50)]
        }
        var speech = [Double](repeating: 0, count: n)
        for w in words { let i = min(n - 1, max(0, Int(w.start))); speech[i] += w.endsSentence || w.text.contains("!") ? 2 : 1 }
        let z = [zscore(s.loudness), zscore(s.motion), zscore(s.scene), zscore(speech)]
        let w = StoryConfig.weights
        let raw = (0..<n).map { w.loudness * z[0][$0] + w.motion * z[1][$0] + w.scene * z[2][$0] + w.speech * z[3][$0] }
        let score = (0..<n).map { i in raw[max(0, i - 1)...min(n - 1, i + 1)].reduce(0, +) / Double(min(n - 1, i + 1) - max(0, i - 1) + 1) }
        var taken = [Bool](repeating: false, count: n), out: [StoryMoment] = []
        var order = score.indices.sorted(by: { score[$0] > score[$1] })
        if buckets > 1 {
            // Coverage: each slice of the timeline contributes its best moment before the global ranking fills the rest.
            let size = Double(n) / Double(buckets)
            let firsts = (0..<buckets).compactMap { b -> Int? in
                let lo = Int(Double(b) * size), hi = min(n - 1, Int(Double(b + 1) * size) - 1)
                return lo <= hi ? (lo...hi).max { score[$0] < score[$1] } : nil
            }
            order = firsts + order.filter { !firsts.contains($0) }
        }
        for i in order where out.count < count && !taken[i] {
            let start = max(0, min(Double(i) - window * 0.6, duration - window)), end = min(duration, start + window)
            let lo = Int(start), hi = min(n - 1, Int(end))
            guard !taken[lo...hi].contains(true) else { continue }
            for k in lo...hi { taken[k] = true }
            // Window average (not peak) so strengths don't all saturate at 100.
            func pct(_ zs: [Double]) -> Int { Int(max(0, min(100, (zs[lo...hi].reduce(0, +) / Double(hi - lo + 1) + 1.5) / 3 * 100))) }
            out.append(StoryMoment(index: 0, start: start, end: end, loudness: pct(z[0]), motion: pct(z[1]), scene: pct(z[2]), speech: pct(z[3])))
        }
        return out.sorted { $0.start < $1.start }.enumerated().map { var m = $1; m.index = $0 + 1; return m }
    }

    static func zscore(_ v: [Double]) -> [Double] {
        let mean = v.reduce(0, +) / Double(max(v.count, 1))
        let sd = sqrt(v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(v.count, 1)))
        return sd < 1e-9 ? v.map { _ in 0 } : v.map { ($0 - mean) / sd }
    }

    /// JPEG frames from inside each moment, for the vision model.
    static func frames(_ moments: [StoryMoment], video: URL, ffmpeg: URL, work: URL, perMoment: Int = StoryConfig.framesPerMoment) async throws -> [StoryMoment] {
        let dir = work.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out = moments
        for i in out.indices {
            let m = out[i], k = perMoment
            out[i].frames = []
            for j in 0..<k {
                let t = m.start + (m.end - m.start) * Double(j + 1) / Double(k + 1)
                let f = dir.appendingPathComponent("m\(m.index)-\(j).jpg")
                try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-ss", String(format: "%.2f", t), "-i", video.path,
                                             "-frames:v", "1", "-vf", "scale=\(StoryConfig.frameWidth):-2", "-q:v", "6", f.path])
                if FileManager.default.fileExists(atPath: f.path) { out[i].frames.append(f.path) }
            }
        }
        return out
    }
}
