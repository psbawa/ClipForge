import Foundation
import ImageIO
import Vision

/// Pro Editor look for a highlight clip (from its style profile). nil = plain render, exactly as before.
public struct ClipLook: Sendable, Equatable {
    public var captionStyle: CaptionStyle
    public var uppercase: Bool
    public var pop: Bool
    public var grade: String            // ffmpeg filter suffix from EditPlanner.grade
    public var punchAt: Double?         // clip-relative peak time for a punch-in
    public var punchScale: Double
    public var hitAt: Double?           // clip-relative impact for a hit sound
    public var cutFillers: Bool         // drop "um/uh" and long pauses
}

public struct RenderedClip: Sendable, Codable, Hashable {
    public var video: URL
    public var srt: URL
    public var start: Double
    public var end: Double
    public var framingSummary = ""
}

public protocol ClipRendering: Actor {
    /// Renders [start, end] (session seconds) to a 1080×1920 Short. `keep` is the scored moment: edges may snap
    /// to a nearby scene cut but never into it. Returns the range actually rendered.
    func render(start: Double, end: Double, keep: ClosedRange<Double>, from segments: [MediaSegment], words: [Word],
                style: CaptionStyle, framing: Framing, voice: VoiceMix?, look: ClipLook?, to dir: URL) async throws -> RenderedClip
    /// Same range, full 16:9 frame with subject boxes, crop window and shot labels drawn on it.
    func debugPreview(start: Double, end: Double, from segments: [MediaSegment], words: [Word], framing: Framing, to dir: URL) async throws -> URL
}

public actor ClipService: ClipRendering {
    let ffmpeg: URL
    public init(ffmpeg: URL) { self.ffmpeg = ffmpeg }

    /// Max distance a clip edge moves to land on a scene cut instead of showing a flash of the neighbouring shot.
    static let cutSnap = 1.0

    /// ffmpeg input args for [s, s+duration] of the buffer (single VOD file or concat of live segments).
    func input(_ segs: [MediaSegment], _ s: Double, _ duration: Double, work: URL) throws -> [String] {
        let first = segs[0]
        if segs.count == 1 { return ["-ss", fmt(s - first.start), "-t", fmt(duration), "-i", first.url.path] }
        let list = work.appendingPathComponent("src.ffconcat")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let body = "ffconcat version 1.0\n" + segs.map { "file '\($0.url.path.replacingOccurrences(of: "'", with: "'\\''"))'\nduration \(fmt($0.end - $0.start))\n" }.joined()
        try body.write(to: list, atomically: true, encoding: .utf8)
        return ["-ss", fmt(s - first.start), "-t", fmt(duration), "-f", "concat", "-safe", "0", "-i", list.path]
    }

    func range(_ start: Double, _ end: Double, _ segments: [MediaSegment]) throws -> (segs: [MediaSegment], s: Double, duration: Double) {
        let segs = segments.filter { $0.end > start && $0.start < end }.sorted { $0.start < $1.start }
        guard let first = segs.first else { throw ClipForgeError("The recording for this moment is no longer in the buffer.") }
        let s = max(start, first.start)
        let duration = min(min(end, segs.last!.end) - s, 180)  // Shorts limit
        guard duration > 1 else { throw ClipForgeError("Clip range is empty") }
        return (segs, s, duration)
    }

    public func render(start: Double, end: Double, keep: ClosedRange<Double>, from segments: [MediaSegment], words: [Word],
                       style: CaptionStyle, framing: Framing, voice: VoiceMix?, look: ClipLook? = nil, to dir: URL) async throws -> RenderedClip {
        var (segs, s, duration) = try range(start, end, segments)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let work = dir.appendingPathComponent("work-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: work) }

        func rel(_ w: [Word], _ from: Double) -> [Word] { w.map { Word($0.text, $0.start - from, $0.end - from) } }
        var plan = try await Reframer.plan(input: try input(segs, s, duration, work: work), duration: duration,
                                           words: rel(words.slice(s, s + duration), s), framing: framing, ffmpeg: ffmpeg, work: work)
        // Temporal boundary: start/end on a scene cut when one sits in the padding, never inside the kept moment.
        let headCut = plan.rawCuts.filter { $0 > 0.05 && $0 <= Self.cutSnap && s + $0 <= keep.lowerBound }.max()
        let tailCut = plan.rawCuts.filter { $0 < duration - 0.05 && duration - $0 <= Self.cutSnap && s + $0 >= keep.upperBound }.min()
        if headCut != nil || tailCut != nil {
            let ns = s + (headCut ?? 0), ne = s + (tailCut ?? duration)
            (segs, s, duration) = try range(ns, ne, segments)
            plan = try await Reframer.plan(input: try input(segs, s, duration, work: work), duration: duration,
                                           words: rel(words.slice(s, s + duration), s), framing: framing, ffmpeg: ffmpeg, work: work)
        }
        let input = try input(segs, s, duration, work: work)

        // Captions: speech, voiceover, or both (voiceover on the upper layer).
        var mainWords = voice?.captions == .replace ? voice!.captionWords : words
        if look?.uppercase == true { mainWords = mainWords.map { Word($0.text.uppercased(), $0.start, $0.end) } }
        let style = look?.captionStyle ?? style
        let captions = try CaptionService.renderOverlay(mainWords, clipStart: s, clipEnd: s + duration, style: style,
                                                        pop: look?.pop ?? false, into: work.appendingPathComponent("captions"))
        let name = "clip-\(Int(s))-\(Int(s + duration))"
        let out = dir.appendingPathComponent(name + ".mp4"), srt = dir.appendingPathComponent(name + ".srt")
        // Pacing: cut fillers and long pauses (not with a voiceover, whose lines are timed to the uncut clip).
        let keep = look?.cutFillers == true && voice == nil ? Self.pacingKeep(rel(words.slice(s, s + duration), s), duration: duration) : nil
        let outDuration = keep.map { $0.reduce(0) { $0 + $1.1 - $1.0 } } ?? duration
        let srtWords = keep.map { k in Self.remap(rel(mainWords.slice(s, s + duration), s), keep: k).map { Word($0.text, $0.start + s, $0.end + s) } } ?? mainWords
        try CaptionService.srt(srtWords, clipStart: s, clipEnd: s + outDuration).write(to: srt, atomically: true, encoding: .utf8)
        try JSONEncoder().encode(plan).write(to: dir.appendingPathComponent(name + ".framing.json"))

        var graph = Reframer.filter(plan, input: "0:v", output: "v", tag: "r")
        var videoIn = "v"
        if let look {
            // Punch-in on the peak (eases in, holds ~2.5 s, eases out), then the profile's grade — under the captions.
            var fx = ""
            if let p = look.punchAt, look.punchScale > 1.01 {
                fx += String(format: ",zoompan=z='if(between(it,%.2f,%.2f),min(pzoom+%.4f,%.3f),max(pzoom-0.02,1))':d=1:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=1080x1920:fps=30",
                             max(0, p - 0.1), p + 2.5, (look.punchScale - 1) / 10, look.punchScale)
            }
            fx += look.grade
            if !fx.isEmpty { graph += ";[v]null" + fx + "[vl]"; videoIn = "vl" }
        }
        graph += ";[1:v]format=rgba[c];[\(videoIn)][c]overlay=0:0:eof_action=pass"
        var extraInputs: [String] = ["-f", "concat", "-safe", "0", "-i", captions.path]
        var next = 2
        if let voice, voice.captions == .add {
            let vc = try CaptionService.renderOverlay(voice.captionWords, clipStart: s, clipEnd: s + duration, style: style,
                                                      placement: .narrative, into: work.appendingPathComponent("voice-captions"))
            extraInputs += ["-f", "concat", "-safe", "0", "-i", vc.path]
            graph += "[vc0];[\(next):v]format=rgba[vcap];[vc0][vcap]overlay=0:0:eof_action=pass"
            next += 1
        }
        let select = keep.map { "'" + $0.map { String(format: "between(t,%.3f,%.3f)", $0.0, $0.1) }.joined(separator: "+") + "'" }
        graph += ",format=yuv420p" + (select.map { ",select=\($0),setpts=N/FRAME_RATE/TB" } ?? "") + "[out]"
        var audioArgs = ["-map", "0:a:0?", "-af", "loudnorm=I=-14:TP=-1.5:LRA=11"]
        if let voice {
            let hasAudio = (try? await StoryAnalyzer.probe(segs[0].url, ffmpeg: ffmpeg).hasAudio) ?? true
            let (g, inputs) = Self.voiceGraph(voice, firstInput: next, hasOriginal: hasAudio, duration: duration)
            graph += ";" + g
            extraInputs += inputs
            audioArgs = ["-map", "[aout]"]
        } else if look?.hitAt != nil || select != nil, (try? await StoryAnalyzer.probe(segs[0].url, ffmpeg: ffmpeg).hasAudio) ?? true {
            var a = "[0:a]aresample=48000,aformat=channel_layouts=stereo[a0]", label = "a0"
            if let hit = look?.hitAt {
                extraInputs += ["-i", try await SFXLibrary.file(.hit, ffmpeg: ffmpeg).path]
                a += ";[\(next):a]aresample=48000,aformat=channel_layouts=stereo,adelay=\(Int(max(0, hit) * 1000)):all=1,volume=0.7[hit]"
                a += ";[a0][hit]amix=inputs=2:duration=first:normalize=0[a1]"
                label = "a1"; next += 1
            }
            a += ";[\(label)]" + (select.map { "aselect=\($0),asetpts=N/SR/TB," } ?? "") + "loudnorm=I=-14:TP=-1.5:LRA=11[aout]"
            graph += ";" + a
            audioArgs = ["-map", "[aout]"]
        }
        try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"] + input + extraInputs + [
            "-filter_complex", graph, "-map", "[out]"] + audioArgs + ["-ar", "48000",
            "-c:v", "h264_videotoolbox", "-b:v", "8M", "-profile:v", "high",
            "-c:a", "aac", "-b:a", "160k", "-t", fmt(outDuration), "-movflags", "+faststart", out.path,
        ])
        return RenderedClip(video: out, srt: srt, start: s, end: s + duration, framingSummary: plan.summary)
    }

    public func debugPreview(start: Double, end: Double, from segments: [MediaSegment], words: [Word], framing: Framing, to dir: URL) async throws -> URL {
        let (segs, s, duration) = try range(start, end, segments)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let work = dir.appendingPathComponent("work-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: work) }
        let input = try input(segs, s, duration, work: work)
        let plan = try await Reframer.plan(input: input, duration: duration,
                                           words: words.slice(s, s + duration).map { Word($0.text, $0.start - s, $0.end - s) }, framing: framing, ffmpeg: ffmpeg, work: work)
        let overlay = try Reframer.debugOverlay(plan, duration: duration, dir: work.appendingPathComponent("debug"))
        let out = dir.appendingPathComponent("clip-\(Int(s))-\(Int(s + duration))-debug.mp4")
        try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"] + input + ["-f", "concat", "-safe", "0", "-i", overlay.path,
            "-filter_complex", "[0:v]scale=1280:-2,setsar=1[v];[1:v]format=rgba,scale=1280:-2[o];[v][o]overlay=0:0:eof_action=pass,format=yuv420p[out]",
            "-map", "[out]", "-map", "0:a:0?", "-c:v", "h264_videotoolbox", "-b:v", "6M", "-c:a", "aac", "-t", fmt(duration), "-movflags", "+faststart", out.path])
        return out
    }

    func fmt(_ d: Double) -> String { String(format: "%.3f", d) }

    static let fillers: Set<String> = ["um", "uh", "erm", "uhm", "hmm", "mm", "ah"]

    /// Clip-relative ranges to keep after cutting filler words and pauses > 0.7 s (each pause keeps 0.25 s on both sides).
    /// nil when less than 0.5 s would be removed. Pure; unit-tested.
    static func pacingKeep(_ words: [Word], duration: Double) -> [(Double, Double)]? {
        var cuts: [(Double, Double)] = []
        for (i, w) in words.enumerated() {
            let t = w.text.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if fillers.contains(t) { cuts.append((w.start, w.end)) }
            if i + 1 < words.count, words[i + 1].start - w.end > 0.7 { cuts.append((w.end + 0.25, words[i + 1].start - 0.25)) }
        }
        let removed = cuts.reduce(0) { $0 + $1.1 - $1.0 }
        guard removed >= 0.5 else { return nil }
        var keep: [(Double, Double)] = [], t = 0.0
        for c in cuts.sorted(by: { $0.0 < $1.0 }) where c.0 > t { keep.append((t, c.0)); t = max(t, c.1) }
        if t < duration { keep.append((t, duration)) }
        return keep.filter { $0.1 - $0.0 > 0.04 }
    }

    /// Clip-relative word times after the pacing cut.
    static func remap(_ words: [Word], keep: [(Double, Double)]) -> [Word] {
        words.compactMap { w in
            var shift = 0.0
            for (i, k) in keep.enumerated() {
                if w.start >= k.0 && w.start < k.1 { return Word(w.text, w.start - shift, min(w.end, k.1) - shift) }
                if i + 1 < keep.count { shift += keep[i + 1].0 - k.1 }
            }
            return nil
        }
    }

    /// Mixes a voiceover onto an already-rendered video (remixes). Video is copied untouched unless voice captions are on.
    static func overlayVoice(video: URL, mix: VoiceMix, duration: Double, canvas: CGSize, style: CaptionStyle,
                             ffmpeg: URL, out: URL, work: URL) async throws {
        let hasAudio = (try? await StoryAnalyzer.probe(video, ffmpeg: ffmpeg).hasAudio) ?? true
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-i", video.path]
        var first = 1
        var graph = ""
        var videoArgs = ["-map", "0:v", "-c:v", "copy"]
        if mix.captions != .off, !mix.captionWords.isEmpty {
            let caps = try CaptionService.renderOverlay(mix.captionWords, clipStart: 0, clipEnd: duration, style: style, placement: .narrative,
                                                        canvas: canvas, into: work.appendingPathComponent("voice-captions"))
            args += ["-f", "concat", "-safe", "0", "-i", caps.path]
            graph = "[1:v]format=rgba[vc];[0:v][vc]overlay=0:0:eof_action=pass,format=yuv420p[vout];"
            videoArgs = ["-map", "[vout]", "-c:v", "h264_videotoolbox", "-b:v", "8M", "-profile:v", "high"]
            first = 2
        }
        let (g, inputs) = voiceGraph(mix, firstInput: first, hasOriginal: hasAudio, duration: duration)
        try await Shell.run(ffmpeg, args + inputs + ["-filter_complex", graph + g] + videoArgs
            + ["-map", "[aout]", "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-t", String(format: "%.3f", duration), "-movflags", "+faststart", out.path])
    }

    /// Voiceover mix: lines placed with adelay, original audio kept/ducked/muted, optional music ducked under the voice.
    /// Returns the audio filter graph (ending in [aout]) and the extra ffmpeg inputs it needs. Pure; unit-tested.
    static func voiceGraph(_ v: VoiceMix, firstInput: Int, hasOriginal: Bool, duration: Double) -> (String, [String]) {
        let T = String(format: "%.3f", duration)
        let norm = "aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo"
        let spans = v.spans.map { ($0.0 - 0.15, $0.1 + 0.25) }
        func under(_ base: Double, _ ducked: Double) -> String {
            guard !spans.isEmpty else { return String(format: "%.3f", base) }
            let inside = spans.map { String(format: "between(t,%.2f,%.2f)", max(0, $0.0), $0.1) }.joined(separator: "+")
            return String(format: "if(gt(%@,0),%.3f,%.3f)", inside, ducked, base)
        }
        var g: [String] = [], mix: [String] = [], inputs: [String] = [], idx = firstInput
        if hasOriginal, v.original != .mute {
            let vol = v.original == .duck ? under(1.0, 0.25) : "1.0"
            g.append("[0:a]\(norm),volume='\(vol)':eval=frame[orig]")
            mix.append("[orig]")
        }
        for (k, line) in v.lines.enumerated() {
            inputs += ["-i", line.url.path]
            let ms = max(0, Int((line.at * 1000).rounded()))
            g.append("[\(idx):a]\(norm),adelay=\(ms):all=1,volume=\(String(format: "%.2f", v.volume))[vo\(k)]")
            mix.append("[vo\(k)]")
            idx += 1
        }
        if let m = v.music {
            inputs += ["-stream_loop", "-1", "-i", m.path]
            g.append("[\(idx):a]\(norm),atrim=0:\(T),asetpts=PTS-STARTPTS,volume='\(under(0.30, 0.08))':eval=frame,"
                + "afade=t=in:d=0.5,afade=t=out:st=\(String(format: "%.3f", max(0, duration - 1.5))):d=1.5[mus]")
            mix.append("[mus]")
        }
        g.append(mix.joined() + "amix=inputs=\(mix.count):duration=longest:normalize=0,atrim=0:\(T),loudnorm=I=-14:TP=-1.5:LRA=11[aout]")
        return (g.joined(separator: ";"), inputs)
    }
}

