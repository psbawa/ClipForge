import Foundation

public struct MusicTrack: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var mood: StoryTone?
    public var isPlaceholder: Bool
    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (isPlaceholder ? "Placeholder · " : "") + url.deletingPathExtension().lastPathComponent }
}

/// Royalty-free music only: tracks the user put in ~/Music/ClipForge/<mood>/, tracks they picked by hand,
/// or simple placeholder tracks ClipForge synthesizes itself with ffmpeg.
public enum MusicLibrary {
    static let audioTypes: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac"]
    static var generatedDir: URL { StoryConfig.musicRoot.appendingPathComponent("_placeholders") }

    /// Creates the mood folders + a README so the user sees where to drop licensed tracks.
    public static func prepareFolders() {
        let fm = FileManager.default
        for m in StoryTone.allCases { try? fm.createDirectory(at: StoryConfig.musicRoot.appendingPathComponent(m.rawValue), withIntermediateDirectories: true) }
        let readme = StoryConfig.musicRoot.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) {
            try? """
            Put royalty-free or licensed music you have the rights to use into the mood folders:
              epic/  funny/  hype/  chill/
            Formats: mp3, m4a, aac, wav, aiff, flac. ClipForge picks a track whose folder matches the story's mood.
            Sources with licences that allow this: YouTube Audio Library, Pixabay Music, or music you made or bought a licence for.
            Never add copyrighted music you don't have the rights to.
            """.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    public static func tracks() -> [MusicTrack] {
        let fm = FileManager.default
        var out: [MusicTrack] = []
        for m in StoryTone.allCases {
            let dir = StoryConfig.musicRoot.appendingPathComponent(m.rawValue)
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where audioTypes.contains(f.pathExtension.lowercased()) {
                out.append(MusicTrack(path: f.path, mood: m, isPlaceholder: false))
            }
        }
        for m in StoryTone.allCases {
            let f = generatedDir.appendingPathComponent("\(m.rawValue).m4a")
            if fm.fileExists(atPath: f.path) { out.append(MusicTrack(path: f.path, mood: m, isPlaceholder: true)) }
        }
        return out.sorted { ($0.isPlaceholder ? 1 : 0, $0.path) < ($1.isPlaceholder ? 1 : 0, $1.path) }
    }

    /// The user's own tracks for the mood first (random among them), then the placeholder for that mood.
    static func pick(mood: StoryTone, ffmpeg: URL) async throws -> MusicTrack {
        if let t = tracks().filter({ $0.mood == mood && !$0.isPlaceholder }).randomElement() { return t }
        return try await placeholder(mood, ffmpeg: ffmpeg)
    }

    // MARK: Placeholder synthesis (fallback so the feature works with an empty library)

    static func placeholder(_ mood: StoryTone, ffmpeg: URL) async throws -> MusicTrack {
        let f = generatedDir.appendingPathComponent("\(mood.rawValue).m4a")
        if !FileManager.default.fileExists(atPath: f.path) {
            try FileManager.default.createDirectory(at: generatedDir, withIntermediateDirectories: true)
            let tmp = generatedDir.appendingPathComponent(".\(mood.rawValue)-\(UUID().uuidString).m4a")
            try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "aevalsrc='\(synth(mood))':s=44100:d=75",
                                         "-af", "lowpass=f=9000,highpass=f=35,afade=t=in:d=0.3,afade=t=out:st=73:d=2,loudnorm=I=-16:TP=-2",
                                         "-ac", "2", "-c:a", "aac", "-b:a", "160k", tmp.path])
            // Atomic: a concurrent tracks() listing must never see a half-written file.
            try? FileManager.default.moveItem(at: tmp, to: f)
            try? FileManager.default.removeItem(at: tmp)
        }
        return MusicTrack(path: f.path, mood: mood, isPlaceholder: true)
    }

    /// aevalsrc expression: kick + bass/pad over a 4-chord loop (+ hats for upbeat moods).
    static func synth(_ mood: StoryTone) -> String {
        let (bpm, root, chords, hats, pluck): (Double, Double, [Int], Bool, Bool) = switch mood {
        case .epic: (84, 55, [0, -4, 3, -2], false, false)      // Am F C G feel
        case .hype: (128, 55, [0, 3, -2, -4], true, false)
        case .funny: (112, 65.4, [0, 5, 7, 5], true, true)      // C F G F, bouncy
        case .chill: (76, 61.7, [0, 5, 3, 7], false, false)
        }
        let p = 60 / bpm
        let bar = String(format: "mod(t/%.4f,4)", 8 * p)  // chord changes every 2 bars
        let semis = "if(lt(\(bar),1),\(chords[0]),if(lt(\(bar),2),\(chords[1]),if(lt(\(bar),3),\(chords[2]),\(chords[3]))))"
        let f = String(format: "%.2f*pow(2,(%@)/12)", root, semis)
        let ph = String(format: "mod(t,%.4f)", p)
        let kickEvery = mood == .chill ? String(format: "mod(t,%.4f)", 2 * p) : ph
        let kick = "0.8*sin(2*PI*50*t+7*exp(-\(kickEvery)*22))*exp(-\(kickEvery)*\(mood == .epic ? 5 : 9))"
        let bassEnv = pluck ? String(format: "exp(-mod(t,%.4f)*10)", p / 2) : "(1-0.6*exp(-\(ph)*7))"
        let bass = "0.30*sin(2*PI*\(f)*t)*\(bassEnv)"
        let pad = "0.10*(sin(2*PI*\(f)*4*t)+0.6*sin(2*PI*\(f)*5.04*t)+0.5*sin(2*PI*\(f)*6*t))*(0.7+0.3*sin(2*PI*t/\(String(format: "%.4f", 4 * p))))"
        let hat = hats ? String(format: "+0.06*(2*random(0)-1)*exp(-mod(t+%.4f,%.4f)*60)", p / 2, p) : ""
        return "\(kick)+\(bass)+\(pad)\(hat)"
    }

    // MARK: Beats

    /// Beat times (seconds) of a track.
    static func beats(_ track: URL, ffmpeg: URL) async throws -> [Double] {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("cf-beats-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: raw) }
        try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-t", "120", "-i", track.path, "-ac", "1", "-ar", "11025", "-f", "f32le", raw.path])
        let d = try Data(contentsOf: raw)
        let samples = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return detectBeats(samples, rate: 11025)
    }

    /// Energy-onset envelope → tempo by autocorrelation (60–180 BPM) → best phase. Pure; unit-tested.
    static func detectBeats(_ x: [Float], rate: Double) -> [Double] {
        let hop = 256, frame = 1024
        guard x.count > frame * 8 else { return [] }
        var energy: [Double] = []
        for s in stride(from: 0, to: x.count - frame, by: hop) {
            var e = 0.0
            for i in s..<(s + frame) { e += Double(x[i] * x[i]) }
            energy.append(log1p(e))
        }
        let rawOnset = [0] + (1..<energy.count).map { max(0, energy[$0] - energy[$0 - 1]) }
        // Light smoothing so a period that falls between two frames still correlates.
        let onset = rawOnset.indices.map { i in 0.25 * rawOnset[max(0, i - 1)] + 0.5 * rawOnset[i] + 0.25 * rawOnset[min(rawOnset.count - 1, i + 1)] }
        let fps = rate / Double(hop)
        let minLag = Int(fps * 60 / 180), maxLag = Int(fps * 60 / 60)
        guard onset.count > maxLag * 2 else { return [] }
        let ac = (0...maxLag + 1).map { lag in lag < minLag - 1 ? 0 : (0..<(onset.count - lag)).reduce(0.0) { $0 + onset[$1] * onset[$1 + lag] } }
        // Mild preference for 90–140 BPM so we don't lock onto half/double time.
        func weight(_ lag: Int) -> Double { let bpm = 60 * fps / Double(lag); return (90...140).contains(bpm) ? 1.0 : 0.85 }
        var lag = (minLag...maxLag).max { ac[$0] * weight($0) < ac[$1] * weight($1) }!
        let half = Int((Double(lag) / 2).rounded())
        if half >= minLag, ac[half] >= 0.6 * ac[lag] { lag = half }
        // Sub-frame period via parabolic interpolation, so beats don't drift over a long track.
        let (y0, y1, y2) = (ac[max(lag - 1, 0)], ac[lag], ac[lag + 1])
        let denom = y0 - 2 * y1 + y2
        let period = Double(lag) + (abs(denom) > 1e-12 ? max(-0.5, min(0.5, 0.5 * (y0 - y2) / denom)) : 0)
        func strength(_ phase: Double) -> Double {
            stride(from: phase, to: Double(onset.count), by: period).reduce(0) { $0 + onset[min(onset.count - 1, Int($1.rounded()))] }
        }
        let phase = stride(from: 0.0, to: period, by: 0.5).max { strength($0) < strength($1) } ?? 0
        return stride(from: phase, to: Double(onset.count), by: period).map { $0 / fps }
    }

    /// Nudges each cut (end of every beat but the last) by ≤ `beatSnap` so it lands on the music's beat grid.
    /// `grid` is in output time (track beats minus the track start offset).
    static func snap(_ beats: [StoryBeat], grid: [Double], duration: Double, maxShift: Double = StoryConfig.beatSnap) -> [StoryBeat] {
        guard !grid.isEmpty, beats.count > 1 else { return beats }
        var out = beats
        for i in 0..<(out.count - 1) {
            let cut = StoryTimeline.starts(out)[i] + out[i].outDuration - StoryTimeline.transition(out[i + 1]).duration / 2
            guard let near = grid.min(by: { abs($0 - cut) < abs($1 - cut) }) else { continue }
            let delta = (near - cut) * out[i].speed   // output seconds → source seconds
            if abs(near - cut) <= maxShift, out[i].duration + delta >= StoryConfig.minBeatSeconds, out[i].end + delta <= duration {
                out[i].end += delta
            }
        }
        return out
    }
}
