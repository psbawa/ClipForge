import Foundation

enum StoryRenderer {
    struct Overlays: Sendable { var narrative: URL; var subtitles: URL? }

    /// Caption layers on the output timeline: (a) one narrative card per beat, (b) karaoke speech subtitles.
    static func captions(_ sb: Storyboard, words: [Word], options: StoryOptions, work: URL) throws -> Overlays {
        let profile = sb.styleID.flatMap(StyleLibrary.profile)
        let capStyle = profile?.captions.style ?? options.captionStyle
        let upper = profile?.captions.uppercase ?? (capStyle == .pop)
        let pop = profile?.captions.animation == "pop"
        let dir = work.appendingPathComponent("captions")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let total = sb.outputDuration, canvas = options.format.canvas
        let blank = dir.appendingPathComponent("blank.png")
        try CaptionService.png(nil, style: .pop, canvas: canvas).write(to: blank)
        var list = "ffconcat version 1.0\n", t = 0.0, last = blank
        func add(_ f: URL, _ d: Double) { if d > 0.01 { list += "file '\(f.lastPathComponent)'\nduration \(String(format: "%.3f", d))\n"; t += d; last = f } }
        for (i, (b, o)) in zip(sb.beats, StoryTimeline.starts(sb.beats)).enumerated() {
            let f = dir.appendingPathComponent(String(format: "n%02d.png", i))
            let text = upper ? b.caption.uppercased() : b.caption
            try CaptionService.png((text.split(separator: " ").map(String.init), -1), style: capStyle, placement: .narrative, canvas: canvas).write(to: f)
            let inXf = i == 0 ? 0 : StoryTimeline.transition(b).duration
            let outXf = i + 1 < sb.beats.count ? StoryTimeline.transition(sb.beats[i + 1]).duration : 0
            add(blank, o + inXf / 2 - t)
            add(f, min(o + b.outDuration - outXf / 2, total) - t)
        }
        add(blank, total - t)
        list += "file '\(last.lastPathComponent)'\n"
        let narrative = dir.appendingPathComponent("narrative.ffconcat")
        try list.write(to: narrative, atomically: true, encoding: .utf8)

        let spoken = StoryTimeline.words(words, beats: sb.beats)
        let subs = options.subtitles && !spoken.isEmpty
            ? try CaptionService.renderOverlay(spoken, clipStart: 0, clipEnd: total, style: capStyle,
                                               placement: .subtitle, canvas: canvas, pop: pop, into: dir.appendingPathComponent("subs"))
            : nil
        return Overlays(narrative: narrative, subtitles: subs)
    }

    /// Music gain over time: ducked while someone speaks or a beat's game audio matters. Pure; unit-tested.
    static func duckIntervals(_ sb: Storyboard, words: [Word]) -> [(Double, Double)] {
        var spans = StoryTimeline.words(words, beats: sb.beats).map { ($0.start - 0.15, $0.end + 0.25) }
        for (b, o) in zip(sb.beats, StoryTimeline.starts(sb.beats)) where b.importantAudio { spans.append((o, o + b.outDuration)) }
        var merged: [(Double, Double)] = []
        for s in spans.sorted(by: { $0.0 < $1.0 }) {
            if let l = merged.last, s.0 <= l.1 + 0.4 { merged[merged.count - 1].1 = max(l.1, s.1) } else { merged.append(s) }
        }
        return merged
    }

    static func volumeExpr(_ spans: [(Double, Double)]) -> String {
        guard !spans.isEmpty else { return String(format: "%.3f", StoryConfig.musicVolume) }
        let inSpan = spans.map { String(format: "between(t,%.2f,%.2f)", max(0, $0.0), $0.1) }.joined(separator: "+")
        return String(format: "if(gt(%@,0),%.3f,%.3f)", inSpan, StoryConfig.duckedVolume, StoryConfig.musicVolume)
    }

    /// Subject-aware framing for one beat in the chosen output shape (shot-by-shot tracking, or blurred-background fill),
    /// plus slow motion. Framing plans are cached per segment, so re-renders after timeline edits don't re-analyze.
    static func videoChain(_ i: Int, beat: StoryBeat, video: URL, words: [Word], mode: StoryCropMode, format: OutputFormat,
                           grade: String = "", ffmpeg: URL, work: URL) async throws -> String {
        let key = String(format: "%.2f-%.2f-%@-%@", beat.start, beat.end, format.rawValue, mode.rawValue)
        let cache = work.appendingPathComponent("framing-cache/\(key).json")
        let plan: Reframer.Plan
        if let d = try? Data(contentsOf: cache), let p = try? JSONDecoder().decode(Reframer.Plan.self, from: d) { plan = p } else {
            let local = words.filter { $0.start >= beat.start && $0.end <= beat.end }.map { Word($0.text, $0.start - beat.start, $0.end - beat.start) }
            plan = try await Reframer.plan(input: ["-ss", String(format: "%.3f", beat.start), "-t", String(format: "%.3f", beat.duration), "-i", video.path],
                                           duration: beat.duration, words: local, framing: mode == .blur ? .blur : .smart,
                                           targetAspect: format.aspect, ffmpeg: ffmpeg, work: work)
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(plan).write(to: cache)
        }
        let slow = beat.speed < 0.999 ? String(format: "setpts=PTS/%.3f,", beat.speed) : ""
        let zoom = beat.zoom.map { $0 > 1.01 ? EditPlanner.punchIn(min($0, 1.3), size: format.size) : "" } ?? ""
        return Reframer.filter(plan, input: "\(i):v", output: "vr\(i)", tag: "b\(i)", size: format.size)
            + ";[vr\(i)]\(slow)fps=\(StoryConfig.fps)\(zoom)\(grade),settb=AVTB[v\(i)]"
    }

    /// One ffmpeg pass: beats → 9:16 → crossfades → narrative + subtitle overlays → game audio + ducked music → H.264/AAC.
    static func render(_ sb: Storyboard, video: URL, hasAudio: Bool, words: [Word], options: StoryOptions,
                       overlays: Overlays, music: MusicTrack?, musicOffset: Double, out: URL, ffmpeg: URL, work: URL) async throws {
        let beats = sb.beats, n = beats.count, total = sb.outputDuration
        let starts = StoryTimeline.starts(beats)
        var args = ["-hide_banner", "-loglevel", "error", "-y"]
        for b in beats { args += ["-ss", String(format: "%.3f", b.start), "-t", String(format: "%.3f", b.duration), "-i", video.path] }
        var g: [String] = []
        for (i, b) in beats.enumerated() {
            g.append(try await videoChain(i, beat: b, video: video, words: words, mode: options.cropMode, format: options.format,
                                          grade: EditPlanner.grade(sb.styleID.flatMap(StyleLibrary.profile)?.color ?? "neutral"), ffmpeg: ffmpeg, work: work))
            let tempo = b.speed < 0.999 ? String(format: "atempo=%.3f,", max(0.5, b.speed)) : ""
            let len = String(format: "%.3f", b.outDuration)
            g.append(hasAudio
                ? "[\(i):a]asetpts=PTS-STARTPTS,\(tempo)aresample=48000,aformat=channel_layouts=stereo,apad,atrim=0:\(len)[a\(i)]"
                : "anullsrc=r=48000:cl=stereo,atrim=0:\(len)[a\(i)]")
        }
        // Per-beat transitions (mostly cuts in remixes; flash/zoom/whip where the plan asks for them).
        var v = "v0", a = "a0"
        for i in 1..<max(n, 1) {
            let (kind, d) = StoryTimeline.transition(beats[i])
            g.append("[\(v)][v\(i)]xfade=transition=\(kind):duration=\(d):offset=\(String(format: "%.3f", starts[i]))[vx\(i)]")
            g.append("[\(a)][a\(i)]acrossfade=d=\(d)[ax\(i)]")
            v = "vx\(i)"; a = "ax\(i)"
        }
        var next = n
        args += ["-f", "concat", "-safe", "0", "-i", overlays.narrative.path]
        g.append("[\(next):v]format=rgba[nar];[\(v)][nar]overlay=0:0:eof_action=pass[vn]")
        v = "vn"; next += 1
        if let subs = overlays.subtitles {
            args += ["-f", "concat", "-safe", "0", "-i", subs.path]
            g.append("[\(next):v]format=rgba[sub];[\(v)][sub]overlay=0:0:eof_action=pass[vs]")
            v = "vs"; next += 1
        }
        g.append("[\(v)]format=yuv420p[vout]")
        // Pro Editor sound design: whooshes, hits and risers placed on the output timeline.
        var sfx: [String] = []
        for (k, cue) in EditPlanner.sfxCues(sb).enumerated() where cue.at < total {
            args += ["-i", try await SFXLibrary.file(cue.kind, ffmpeg: ffmpeg).path]
            g.append("[\(next):a]aresample=48000,aformat=channel_layouts=stereo,adelay=\(Int(cue.at * 1000)):all=1,volume=\(cue.kind == .riser ? 0.5 : 0.8)[fx\(k)]")
            sfx.append("[fx\(k)]")
            next += 1
        }
        if !sfx.isEmpty {
            g.append("[\(a)]" + sfx.joined() + "amix=inputs=\(sfx.count + 1):duration=first:normalize=0[asfx]")
            a = "asfx"
        }
        if let music {
            args += ["-stream_loop", "-1", "-ss", String(format: "%.3f", musicOffset), "-i", music.path]
            let T = String(format: "%.3f", total)
            g.append("[\(next):a]aresample=48000,aformat=channel_layouts=stereo,atrim=0:\(T),asetpts=PTS-STARTPTS,"
                + "volume='\(volumeExpr(duckIntervals(sb, words: words)))':eval=frame,"
                + "afade=t=in:d=\(StoryConfig.musicFadeIn),afade=t=out:st=\(String(format: "%.3f", max(0, total - StoryConfig.musicFadeOut))):d=\(StoryConfig.musicFadeOut)[mus]")
            g.append("[\(a)][mus]amix=inputs=2:duration=first:normalize=0,loudnorm=I=-14:TP=-1.5:LRA=11[aout]")
        } else {
            g.append("[\(a)]loudnorm=I=-14:TP=-1.5:LRA=11[aout]")
        }
        args += ["-filter_complex", g.joined(separator: ";"), "-map", "[vout]", "-map", "[aout]",
                 "-c:v", "h264_videotoolbox", "-b:v", StoryConfig.videoBitrate, "-profile:v", "high", "-r", "\(StoryConfig.fps)",
                 "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-t", String(format: "%.3f", total), "-movflags", "+faststart", out.path]
        try await Shell.run(ffmpeg, args)
    }
}
