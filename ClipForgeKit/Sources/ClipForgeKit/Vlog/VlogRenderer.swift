import CryptoKit
import Foundation

/// Segment-first rendering: every beat becomes a cached, uniform segment file (from the ORIGINAL footage), then one
/// cheap pass concatenates them and adds captions, music and loudness. Crash-safe: finished segments are reused.
enum VlogRenderer {
    struct Output: Sendable { var format: OutputFormat; var vibe: VlogVibe; var talkLoudness: Double = -16 }

    static func key(_ b: StoryBeat, _ a: VlogAsset, _ o: Output, targetLuma: Double) -> String {
        let s = [a.id, String(format: "%.2f|%.2f", b.start, b.end), o.format.rawValue, o.vibe.rawValue, String(format: "%.2f", targetLuma),
                 b.zoom.map { String(format: "%.2f", $0) } ?? "-"].joined(separator: "|")
        return SHA256.hash(data: Data(s.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// Exposure match toward the footage median + the vibe's grade.
    static func colorFilter(_ a: VlogAsset, targetLuma: Double, vibe: VlogVibe) -> String {
        let delta = max(-0.08, min(0.08, (targetLuma - a.brightness) * 0.6))
        return String(format: ",eq=brightness=%.3f", delta) + EditPlanner.grade(vibe.color)
    }

    static func segment(_ b: StoryBeat, asset a: VlogAsset, output o: Output, targetLuma: Double, ffmpeg: URL, dir: URL) async throws -> URL {
        let out = dir.appendingPathComponent(key(b, a, o, targetLuma: targetLuma) + ".mp4")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let (W, H) = o.format.size
        let dur = String(format: "%.3f", b.duration)
        let tmp = dir.appendingPathComponent(UUID().uuidString + ".part.mp4")
        var args = ["-hide_banner", "-loglevel", "error", "-y"]
        var graph: String
        let color = colorFilter(a, targetLuma: targetLuma, vibe: o.vibe)
        if a.isPhoto {
            // Ken Burns: slow zoom from 1.0 to ~1.08 over the beat.
            let frames = Int(b.duration * Double(StoryConfig.fps))
            args += ["-loop", "1", "-framerate", "\(StoryConfig.fps)", "-t", dur, "-i", a.path, "-f", "lavfi", "-t", dur, "-i", "anullsrc=r=48000:cl=stereo"]
            graph = "[0:v]scale=\(W * 2):\(H * 2):force_original_aspect_ratio=increase,crop=\(W * 2):\(H * 2),"
                + "zoompan=z='min(1+on/\(max(frames, 1))*0.08,1.08)':d=1:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=\(W)x\(H):fps=\(StoryConfig.fps)\(color),setsar=1,format=yuv420p[v];[1:a]anull[a]"
        } else {
            args += ["-ss", String(format: "%.3f", b.start), "-t", dur, "-i", a.path]
            let plan = try await Reframer.plan(input: ["-ss", String(format: "%.3f", b.start), "-t", dur, "-i", a.proxyPath ?? a.path],
                                               duration: b.duration, words: [], framing: .smart, targetAspect: o.format.aspect,
                                               ffmpeg: ffmpeg, work: dir)
            let stab = a.shake > 0.35 ? "deshake," : ""
            let zoom = b.zoom.map { $0 > 1.01 ? EditPlanner.punchIn(min($0, 1.2), size: o.format.size) : "" } ?? ""
            graph = "[0:v]\(stab)null[src];" + Reframer.filter(plan, input: "src", output: "fr", tag: "s", size: o.format.size)
                + ";[fr]null\(zoom)\(color),setsar=1,format=yuv420p[v]"
            if a.hasAudio {
                let clean = a.talking ? "afftdn=nf=-25," : ""
                let level = a.talking ? o.talkLoudness : -24     // ambience sits under music; talking is clear
                graph += ";[0:a]\(clean)aresample=48000,aformat=channel_layouts=stereo,loudnorm=I=\(Int(level)):TP=-2:LRA=11,apad,atrim=0:\(dur)[a]"
            } else {
                args += ["-f", "lavfi", "-t", dur, "-i", "anullsrc=r=48000:cl=stereo"]
                graph += ";[1:a]anull[a]"
            }
        }
        args += ["-filter_complex", graph, "-map", "[v]", "-map", "[a]", "-r", "\(StoryConfig.fps)", "-c:v", "h264_videotoolbox", "-b:v", "10M",
                 "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-t", dur, tmp.path]
        try await Shell.run(ffmpeg, args)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    /// Output-time words for speech subtitles (talking beats only), and the spans to duck music under.
    static func speech(_ sb: Storyboard, assets: [String: VlogAsset]) -> [Word] {
        var out: [Word] = [], t = 0.0
        for b in sb.beats {
            if let a = b.asset.flatMap({ assets[$0] }), a.talking {
                out += a.words.filter { $0.start >= b.start && $0.end <= b.end }.map { Word($0.text, t + $0.start - b.start, t + $0.end - b.start) }
            }
            t += b.duration
        }
        return out
    }

    /// "00:00 Intro" lines (YouTube chapters need the first at 00:00 and ≥ 3 entries).
    static func chapterMarks(_ sb: Storyboard, chapters: [VlogChapter]) -> [String] {
        var marks: [String] = ["00:00 Intro"], t = 0.0, seen = Set<Int>()
        for b in sb.beats {
            if let c = b.chapter, !seen.contains(c), let ch = chapters.first(where: { $0.index == c }) {
                seen.insert(c)
                if t >= 10 { marks.append(String(format: "%02d:%02d %@", Int(t) / 60, Int(t) % 60, ch.title)) }
            }
            t += b.duration
        }
        return marks.count >= 3 ? marks : []
    }

    static func render(_ sb: Storyboard, assets: [String: VlogAsset], chapters: [VlogChapter], output o: Output, music: [MusicTrack],
                       options: StoryOptions, ffmpeg: URL, work: URL, out: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let segDir = work.appendingPathComponent("segments")
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        let lumas = assets.values.filter { !$0.isPhoto && $0.rejected == nil }.map(\.brightness).sorted()
        let target = lumas.isEmpty ? 0.45 : lumas[lumas.count / 2]
        var files: [URL] = []
        for (i, b) in sb.beats.enumerated() {
            try Task.checkCancellation()
            guard let id = b.asset, let a = assets[id] else { throw ClipForgeError("Beat \(i + 1) references a missing file.") }
            files.append(try await segment(b, asset: a, output: o, targetLuma: target, ffmpeg: ffmpeg, dir: segDir))
            progress(Double(i + 1) / Double(sb.beats.count) * 0.85)
        }
        let total = sb.beats.map(\.duration).reduce(0, +)
        let list = work.appendingPathComponent("segments.ffconcat")
        try ("ffconcat version 1.0\n" + files.map { "file '\($0.path)'\n" }.joined()).write(to: list, atomically: true, encoding: .utf8)

        // Captions: chapter/title cards + beat captions (narrative), speech subtitles.
        var vlogBoard = sb
        for i in vlogBoard.beats.indices { vlogBoard.beats[i].transition = "cut"; vlogBoard.beats[i].speed = 1 }
        let capDir = work.appendingPathComponent("captions-\(o.format.rawValue)")
        var o2 = options; o2.format = o.format; o2.subtitles = false
        let overlays = try StoryRenderer.captions(vlogBoard, words: [], options: o2, work: capDir)
        let spoken = speech(sb, assets: assets)
        let subs = options.subtitles && !spoken.isEmpty
            ? try CaptionService.renderOverlay(spoken, clipStart: 0, clipEnd: total, style: options.captionStyle, placement: .subtitle,
                                               canvas: o.format.canvas, into: capDir.appendingPathComponent("subs"))
            : nil

        var args = ["-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", list.path,
                    "-f", "concat", "-safe", "0", "-i", overlays.narrative.path]
        var g = ["[1:v]format=rgba[nar];[0:v][nar]overlay=0:0:eof_action=pass[v1]"]
        var v = "v1", next = 2
        if let subs {
            args += ["-f", "concat", "-safe", "0", "-i", subs.path]
            g.append("[\(next):v]format=rgba[sub];[\(v)][sub]overlay=0:0:eof_action=pass[v2]"); v = "v2"; next += 1
        }
        g.append("[\(v)]format=yuv420p[vout]")
        // Music bed: one track per chapter (crossfaded), ducked under talking.
        let spans = spoken.map { ($0.start - 0.2, $0.end + 0.3) }
        var merged: [(Double, Double)] = []
        for s in spans.sorted(by: { $0.0 < $1.0 }) { if let l = merged.last, s.0 <= l.1 + 0.5 { merged[merged.count - 1].1 = max(l.1, s.1) } else { merged.append(s) } }
        var bed: URL?
        defer { if let bed { try? FileManager.default.removeItem(at: bed) } }
        if !music.isEmpty {
            // The bed is its own capped pass: looped inputs inside the big graph never reach EOF and hang the render.
            bed = try await musicBed(sb, tracks: music, total: total, duck: merged, ffmpeg: ffmpeg, work: work)
            args += ["-i", bed!.path]
            g.append("[0:a][\(next):a]amix=inputs=2:duration=first:normalize=0,loudnorm=I=\(o.format == .vertical ? -14 : -16):TP=-1.5:LRA=11[aout]")
        } else {
            g.append("[0:a]loudnorm=I=-16:TP=-1.5:LRA=11[aout]")
        }
        let tmp = work.appendingPathComponent("final-\(UUID().uuidString.prefix(6)).mp4")
        args += ["-filter_complex", g.joined(separator: ";"), "-map", "[vout]", "-map", "[aout]", "-c:v", "h264_videotoolbox", "-b:v", o.format == .landscape ? "12M" : "8M",
                 "-profile:v", "high", "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-t", String(format: "%.3f", total), "-movflags", "+faststart", tmp.path]
        try await Shell.run(ffmpeg, args)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        progress(1)
    }

    /// One track per chapter, crossfaded, ducked under talking, faded in/out; exactly `total` seconds long.
    static func musicBed(_ sb: Storyboard, tracks: [MusicTrack], total: Double, duck: [(Double, Double)], ffmpeg: URL, work: URL) async throws -> URL {
        let pieces = musicPieces(sb, tracks: tracks)
        var args = ["-hide_banner", "-loglevel", "error", "-y"], g: [String] = [], labels: [String] = []
        for (k, p) in pieces.enumerated() {
            args += ["-stream_loop", "-1", "-i", p.track.path]
            g.append("[\(k):a]aresample=48000,aformat=channel_layouts=stereo,atrim=0:\(String(format: "%.3f", p.length + 1.5)),asetpts=PTS-STARTPTS[m\(k)]")
            labels.append("[m\(k)]")
        }
        var bed = labels[0]
        for k in labels.indices.dropFirst() { g.append("\(bed)\(labels[k])acrossfade=d=1.5[mb\(k)]"); bed = "[mb\(k)]" }
        g.append("\(bed)atrim=0:\(String(format: "%.3f", total)),volume='\(StoryRenderer.volumeExpr(duck))':eval=frame,"
            + "afade=t=in:d=1,afade=t=out:st=\(String(format: "%.3f", max(0, total - 2))):d=2[mus]")
        let out = work.appendingPathComponent("music-bed-\(UUID().uuidString.prefix(6)).m4a")
        try await Shell.run(ffmpeg, args + ["-filter_complex", g.joined(separator: ";"), "-map", "[mus]", "-t", String(format: "%.3f", total),
                                            "-c:a", "aac", "-b:a", "192k", out.path])
        return out
    }

    /// Chapter-length pieces of music (one track per chapter, cycling through the list).
    static func musicPieces(_ sb: Storyboard, tracks: [MusicTrack]) -> [(track: MusicTrack, length: Double)] {
        var pieces: [(MusicTrack, Double)] = [], current: Int?, len = 0.0
        for b in sb.beats {
            let c = b.chapter ?? 0
            if current != nil, c != current { pieces.append((tracks[pieces.count % tracks.count], len)); len = 0 }
            current = c; len += b.duration
        }
        pieces.append((tracks[pieces.count % tracks.count], len))
        return pieces
    }
}
