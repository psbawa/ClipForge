import AppKit
import Foundation
import ImageIO
import Vision

/// Subject-aware 16:9 → 9:16 reframing, shared by highlight clips and Story Shorts.
///
/// 1. Sample frames at `sampleFPS` and detect scene cuts in the same ffmpeg pass.
/// 2. Per frame (Vision): faces (+ mouth openness), people, motion centroid, saliency.
/// 3. Per shot: pick the subject (active speaker / everyone who fits / person / motion / saliency),
///    or fall back to a blurred-background fill when it can't fit.
/// 4. Smooth the crop path inside each shot (dead zone + max pan speed + zero-phase average);
///    jumps only happen at cuts. Headroom: faces stay in the upper part, clear of the bottom 20%.
/// How a clip is framed. Smart is the default; Blur and Manual are per-clip overrides from the review screen.
public enum Framing: Codable, Sendable, Hashable {
    case smart
    case blur
    case manual(Double)   // crop centre, fraction of source width

    var raw: String {
        switch self {
        case .smart: "smart"
        case .blur: "blur"
        case .manual(let x): String(format: "manual:%.4f", x)
        }
    }
    init(raw: String?) {
        if raw == "blur" { self = .blur }
        else if let r = raw, r.hasPrefix("manual:"), let x = Double(r.dropFirst(7)) { self = .manual(x) }
        else { self = .smart }
    }
}

enum Reframer {
    static let sampleFPS = 4.0
    static let sceneThreshold = 12.0          // scdet score (0–100) that counts as a cut
    static let maxZoom = 1.15                  // allowed zoom-in to fix headroom
    static let panSpeed = 0.35                 // max crop movement, fraction of source width per second
    static let deadZone = 0.18                 // subject may drift this far (fraction of crop width) before we pan
    static let captionZone = 0.80              // faces must stay above this line (fraction of output height)
    static let minShot = 0.6                   // ignore "cuts" closer together than this (flashes)

    // MARK: Data

    struct Box: Codable, Sendable, Equatable {
        var x, y, w, h: Double                 // normalized, origin top-left
        var midX: Double { x + w / 2 }
        var maxX: Double { x + w }
        var maxY: Double { y + h }
        func union(_ o: Box) -> Box {
            let x0 = min(x, o.x), y0 = min(y, o.y)
            return Box(x: x0, y: y0, w: max(maxX, o.maxX) - x0, h: max(maxY, o.maxY) - y0)
        }
    }

    struct Face: Codable, Sendable { var box: Box; var mouth: Double }

    struct Sample: Codable, Sendable {
        var t: Double
        var faces: [Face] = []
        var people: [Box] = []
        var motion: Box?
        var salient: Box?
    }

    enum Mode: String, Codable, Sendable { case track, fill }

    struct Shot: Codable, Sendable {
        var start: Double, end: Double         // clip-relative seconds
        var mode: Mode
        var zoom: Double = 1
        var top: Double = 0                    // crop top edge, fraction of source height
        var keys: [Double] = []                // crop centre x per sample in this shot (fraction of source width)
        var keyTimes: [Double] = []            // shot-relative times of `keys`
        var subjects: [Box?] = []              // debug: chosen subject per sample
        var reason = ""
    }

    struct Plan: Codable, Sendable {
        var aspect: Double                     // source width / height
        var targetAspect = 9.0 / 16.0          // output width / height
        var shots: [Shot]
        var samples: [Sample]
        var cuts: [Double]                     // shot boundaries used for framing
        var rawCuts: [Double] = []             // every detected cut, including ones right at the clip edges
        var cropWidth: Double { min(1, targetAspect / aspect) }  // fraction of source width at zoom 1

        /// One line for logs and the review screen: what was detected and how each shot was framed.
        var summary: String {
            let tracked = shots.filter { $0.mode == .track }, filled = shots.filter { $0.mode == .fill }
            func counts(_ s: [Shot]) -> String { Dictionary(grouping: s, by: \.reason).map { "\($0.key) ×\($0.value.count)" }.sorted().joined(separator: ", ") }
            let det = "faces in \(samples.filter { !$0.faces.isEmpty }.count)/\(samples.count) frames, people in \(samples.filter { !$0.people.isEmpty }.count), motion in \(samples.filter { $0.motion != nil }.count)"
            return "\(shots.count) shot\(shots.count == 1 ? "" : "s"): \(tracked.count) cropped (\(counts(tracked)))"
                + (filled.isEmpty ? "" : ", \(filled.count) blur fill (\(counts(filled)))") + " · \(det)"
        }
    }

    // MARK: Analysis

    /// `input` are ffmpeg input args (with -ss/-t) for the clip range; times in the plan are clip-relative.
    static func plan(input: [String], duration: Double, words: [Word], framing: Framing = .smart, targetAspect: Double = 9.0 / 16.0,
                     ffmpeg: URL, work: URL) async throws -> Plan {
        let dir = work.appendingPathComponent("reframe-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cutsFile = dir.appendingPathComponent("cuts.txt")
        let graph = "[0:v]split=2[a][b];[a]fps=\(sampleFPS),scale=480:-2[f];"
            + "[b]scale=320:-2,scdet=threshold=\(sceneThreshold),metadata=mode=print:file='\(StoryAnalyzer.esc(cutsFile.path))'[c]"
        try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error"] + input + ["-filter_complex", graph,
            "-map", "[f]", dir.appendingPathComponent("f%05d.jpg").path, "-map", "[c]", "-f", "null", "-"])
        let files = (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "jpg" }.sorted { $0.path < $1.path }
        var aspect = 16.0 / 9.0
        var samples: [Sample] = []
        var prev: [UInt8]?
        for (i, f) in files.enumerated() {
            guard let src = CGImageSourceCreateWithURL(f as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            if i == 0 { aspect = Double(img.width) / Double(img.height) }
            var s = detect(img, t: Double(i) / sampleFPS)
            let gray = thumbnail(img)
            if let prev { s.motion = motionBox(prev, gray) }
            prev = gray
            samples.append(s)
        }
        let cutText = (try? String(contentsOf: cutsFile, encoding: .utf8)) ?? ""
        let cuts = StoryAnalyzer.parse(cutText, keys: ["lavfi.scd.time"])["lavfi.scd.time"]?.map(\.1) ?? []
        let plan = build(samples: samples, cuts: cuts, duration: duration, aspect: aspect, words: words, framing: framing, targetAspect: targetAspect)
        Log.app.info("Framing: \(plan.summary, privacy: .public)")
        return plan
    }

    static func detect(_ img: CGImage, t: Double) -> Sample {
        let faces = VNDetectFaceLandmarksRequest()
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = true   // head + shoulders: centres on the head even in profile
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: img).perform([faces, people, saliency])
        func box(_ r: CGRect) -> Box { Box(x: r.minX, y: 1 - r.maxY, w: r.width, h: r.height) } // Vision is bottom-left
        var s = Sample(t: t)
        s.faces = (faces.results ?? []).filter { $0.confidence > 0.5 && $0.boundingBox.width > 0.025 }.map { f in
            var mouth = 0.0
            if let lips = f.landmarks?.innerLips?.normalizedPoints, !lips.isEmpty {
                let ys = lips.map(\.y)
                mouth = Double((ys.max()! - ys.min()!))   // relative to face box height
            }
            return Face(box: box(f.boundingBox), mouth: mouth)
        }
        s.people = (people.results ?? []).filter { $0.confidence > 0.5 }.map { box($0.boundingBox) }
        if let o = saliency.results?.first?.salientObjects?.max(by: { $0.confidence < $1.confidence }) { s.salient = box(o.boundingBox) }
        return s
    }

    static let thumbW = 64, thumbH = 36

    static func thumbnail(_ img: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: thumbW * thumbH)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: thumbW, height: thumbH, bitsPerComponent: 8, bytesPerRow: thumbW,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.interpolationQuality = .low
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))
        }
        return px
    }

    /// Where things moved between two frames: intensity-weighted centroid of the changed pixels, as a small box.
    /// Static HUD pixels never change, so they're ignored. Whole-frame change (camera pan, cut) gives nil.
    static func motionBox(_ a: [UInt8], _ b: [UInt8]) -> Box? {
        var diffs = [Int](repeating: 0, count: a.count)
        for i in a.indices { diffs[i] = abs(Int(a[i]) - Int(b[i])) }
        let thresh = max(18, diffs.sorted()[Int(Double(diffs.count) * 0.9)])
        var sx = 0.0, sy = 0.0, sw = 0.0, n = 0
        for i in diffs.indices where diffs[i] >= thresh {
            let w = Double(diffs[i])
            // CGContext rows are bottom-up; convert to top-left origin.
            sx += w * (Double(i % thumbW) + 0.5) / Double(thumbW)
            sy += w * (Double(thumbH - 1 - i / thumbW) + 0.5) / Double(thumbH)
            sw += w; n += 1
        }
        guard n >= 8, Double(n) < Double(diffs.count) * 0.45 else { return nil }
        return Box(x: sx / sw - 0.04, y: sy / sw - 0.04, w: 0.08, h: 0.08)
    }

    // MARK: Planning (pure — unit-tested)

    static func build(samples: [Sample], cuts rawCuts: [Double], duration: Double, aspect: Double,
                      words: [Word], framing: Framing, targetAspect: Double = 9.0 / 16.0) -> Plan {
        var plan = Plan(aspect: aspect, targetAspect: targetAspect, shots: [], samples: samples, cuts: [], rawCuts: rawCuts.sorted())
        var cuts: [Double] = []
        for c in rawCuts.sorted() where c > minShot && c < duration - minShot && (cuts.last.map { c - $0 >= minShot } ?? true) { cuts.append(c) }
        plan.cuts = cuts
        let bounds = [0] + cuts + [duration]
        let cw = plan.cropWidth
        for i in 0..<(bounds.count - 1) {
            let (s, e) = (bounds[i], bounds[i + 1])
            let inShot = samples.filter { $0.t >= s - 0.01 && $0.t < e }
            plan.shots.append(shot(inShot, start: s, end: e, cropWidth: cw, aspect: aspect, words: words, framing: framing))
        }
        return plan
    }

    /// Is someone speaking at time t (clip-relative)?
    static func speaking(_ words: [Word], _ t: Double) -> Bool { words.contains { $0.start - 0.2 <= t && t <= $0.end + 0.2 } }

    /// Gameplay / no people: blend where things move, what's salient (down-weighted at the edges, where HUDs live)
    /// and the screen centre (crosshair / third-person character).
    static func actionCenter(_ s: Sample) -> Double {
        var sum = 0.25 * 0.5, weight = 0.25
        if let m = s.motion { sum += 0.5 * m.midX; weight += 0.5 }
        if let sal = s.salient {
            let w = sal.midX < 0.12 || sal.midX > 0.88 ? 0.05 : 0.25
            sum += w * sal.midX; weight += w
        }
        return sum / weight
    }

    static func shot(_ samples: [Sample], start: Double, end: Double, cropWidth cw: Double, aspect: Double,
                     words: [Word], framing: Framing) -> Shot {
        var shot = Shot(start: start, end: end, mode: .track)
        if cw >= 0.999 { shot.mode = .fill; shot.reason = "source already fits the output shape"; return shot }
        switch framing {
        case .blur: shot.mode = .fill; shot.reason = "fit with blur (manual)"; return shot
        case .manual(let x):
            let c = min(1 - cw / 2, max(cw / 2, x))
            shot.keys = [c]; shot.keyTimes = [0]; shot.reason = "manual position"; return shot
        case .smart: break
        }
        guard !samples.isEmpty else { shot.keys = [0.5]; shot.keyTimes = [0]; shot.reason = "no samples (centre)"; return shot }

        // Active speaker: the face whose mouth moves most while someone talks (faces matched by position).
        let multi = samples.filter { $0.faces.count >= 2 }
        var speakerX: Double?
        if multi.count >= max(2, samples.count / 3) {
            var activity: [Double: (sum: Double, n: Int, prev: Double?)] = [:]  // keyed by rounded centre x
            for s in samples where speaking(words, s.t) {
                for f in s.faces {
                    let k = (f.box.midX * 8).rounded() / 8
                    var a = activity[k] ?? (0, 0, nil)
                    if let p = a.prev { a.sum += abs(f.mouth - p) }
                    a.prev = f.mouth; a.n += 1
                    activity[k] = a
                }
            }
            if let best = activity.filter({ $0.value.n >= 3 }).max(by: { $0.value.sum / Double($0.value.n) < $1.value.sum / Double($1.value.n) }),
               best.value.sum / Double(best.value.n) > 0.01 {
                speakerX = best.key
            }
        }

        // Subject per sample: faces → people → centre of action. Only several people who can't share the
        // 9:16 window (and no clear speaker) count against cropping — a single subject always gets tracked.
        var peopleDontFit = 0
        var faceTops: [Double] = [], faceBottoms: [Double] = []
        shot.subjects = samples.map { s in
            if !s.faces.isEmpty {
                let all = s.faces.dropFirst().reduce(s.faces[0].box) { $0.union($1.box) }
                let pick: Box
                if all.w <= cw * 0.9 { pick = all }
                else if let sx = speakerX, let f = s.faces.min(by: { abs($0.box.midX - sx) < abs($1.box.midX - sx) }) { pick = f.box }
                else { peopleDontFit += 1; pick = s.faces.max(by: { $0.box.w < $1.box.w })!.box }
                faceTops.append(pick.y); faceBottoms.append(pick.maxY)
                return pick
            }
            if !s.people.isEmpty {
                let all = s.people.dropFirst().reduce(s.people[0]) { $0.union($1) }
                if s.people.count >= 2, all.w > cw * 1.05 { peopleDontFit += 1 }
                return s.people.count >= 2 && all.w <= cw * 1.05 ? all : s.people.max(by: { $0.w * $0.h < $1.w * $1.h })!
            }
            let c = actionCenter(s)
            return Box(x: c - 0.04, y: 0.46, w: 0.08, h: 0.08)
        }
        if Double(peopleDontFit) > Double(samples.count) * 0.5 {
            shot.mode = .fill; shot.reason = "people too far apart to fit 9:16, no clear speaker"; return shot
        }

        // Headroom: if faces sit low, zoom in a little and shift the crop down so they land in the upper part.
        if let bottom = faceBottoms.sorted().dropFirst(faceBottoms.count / 2).first, let top = faceTops.sorted().first {
            let limit = captionZone - 0.1
            if bottom > limit {
                let zoom = min(maxZoom, max(1, bottom / limit))
                let h = 1 / zoom
                shot.zoom = zoom
                // Lowest offset that lifts the face above the caption line, but never so low it cuts the top of the head.
                shot.top = max(0, min(bottom - limit * h, min(1 - h, max(0, top - 0.08 * h))))
            }
        }

        // Smooth path: hold through gaps, follow with a dead zone and pan-speed limit, then zero-phase average.
        let effW = cw / shot.zoom
        var raw: [Double] = []
        var last = shot.subjects.compactMap { $0?.midX }.first ?? 0.5
        for b in shot.subjects { if let b { last = b.midX }; raw.append(last) }
        shot.keyTimes = samples.map { $0.t - start }
        shot.keys = smoothPath(raw, cropWidth: effW, dt: 1 / sampleFPS)
        shot.reason = !samples.contains(where: { !$0.faces.isEmpty }) ? (samples.contains { !$0.people.isEmpty } ? "person" : "centre of action")
            : speakerX != nil ? "active speaker" : "face"
        return shot
    }

    static func smoothPath(_ raw: [Double], cropWidth cw: Double, dt: Double) -> [Double] {
        guard let first = raw.first else { return [] }
        let half = cw / 2
        func clamp(_ x: Double) -> Double { min(1 - half, max(half, x)) }
        var c = clamp(first), out: [Double] = []
        let maxStep = panSpeed * dt, dz = deadZone * cw
        for x in raw {
            let d = clamp(x) - c
            if abs(d) > dz { c += (d > 0 ? 1 : -1) * min(maxStep, abs(d) - dz) }
            out.append(c)
        }
        return out.indices.map { i in
            let w = out[max(0, i - 2)...min(out.count - 1, i + 2)]
            return clamp(w.reduce(0, +) / Double(w.count))
        }
    }

    // MARK: Rendering

    /// Piecewise-linear ffmpeg expression of `t` through (times[i], values[i]).
    static func expression(_ v: [Double], times: [Double]) -> String {
        guard v.count > 1 else { return String(format: "%.4f", v.first ?? 0.5) }
        var e = String(format: "%.4f", v.last!)
        for i in stride(from: v.count - 2, through: 0, by: -1) {
            let dt = max(times[i + 1] - times[i], 0.001), slope = (v[i + 1] - v[i]) / dt
            e = String(format: "if(lt(t,%.3f),%.4f+(%.5f)*(t-%.3f),%@)", times[i + 1], v[i], slope, times[i], e)
        }
        return e
    }

    /// Filter graph turning `input` (a video label) into `output` at 1080×1920, shot by shot.
    static func filter(_ plan: Plan, input: String, output: String, tag: String, size: (w: Int, h: Int) = (1080, 1920)) -> String {
        let (W, H) = size, A = String(format: "%.5f", plan.targetAspect)
        let n = plan.shots.count
        var g = n > 1 ? ["[\(input)]split=\(n)" + (0..<n).map { "[\(tag)s\($0)]" }.joined()] : []
        for (i, s) in plan.shots.enumerated() {
            let src = n > 1 ? "[\(tag)s\(i)]" : "[\(input)]"
            let trim = String(format: "trim=start=%.3f:end=%.3f,setpts=PTS-STARTPTS", s.start, s.end)
            if s.mode == .fill {
                g.append("\(src)\(trim),split=2[\(tag)b\(i)][\(tag)f\(i)]")
                g.append("[\(tag)b\(i)]scale=\(W):\(H):force_original_aspect_ratio=increase,crop=\(W):\(H),gblur=sigma=40,eq=brightness=-0.08[\(tag)bb\(i)]")
                g.append("[\(tag)f\(i)]scale=\(W):\(H):force_original_aspect_ratio=decrease[\(tag)ff\(i)]")
                g.append("[\(tag)bb\(i)][\(tag)ff\(i)]overlay=(W-w)/2:(H-h)/2,setsar=1[\(tag)o\(i)]")
            } else {
                let z = String(format: "%.4f", s.zoom), top = String(format: "%.4f", s.top)
                let x = expression(s.keys, times: s.keyTimes)
                g.append("\(src)\(trim),crop=w='min(iw,ih*\(A))/\(z)':h='min(ih,iw/\(A))/\(z)':x='max(0,min(iw-ow,(\(x))*iw-ow/2))':y='\(top)*ih',scale=\(W):\(H),setsar=1[\(tag)o\(i)]")
            }
        }
        g.append((0..<n).map { "[\(tag)o\($0)]" }.joined() + (n > 1 ? "concat=n=\(n):v=1:a=0," : "null,") + "fps=30,format=yuv420p[\(output)]")
        return g.joined(separator: ";")
    }

    // MARK: Debug overlay

    /// PNG frames (1280×720) with subject boxes (green), crop window (yellow) and shot labels; ffconcat list.
    static func debugOverlay(_ plan: Plan, duration: Double, dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let W = 1280.0, H = W / plan.aspect
        var list = "ffconcat version 1.0\n", last = ""
        let step = 1 / sampleFPS
        for (i, smp) in plan.samples.enumerated() {
            guard let shot = plan.shots.first(where: { smp.t >= $0.start - 0.01 && smp.t < $0.end }) ?? plan.shots.last else { continue }
            let k = shot.keyTimes.firstIndex { abs($0 - (smp.t - shot.start)) < 0.01 }
            let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)        // top-left origin
            func rect(_ b: Box) -> CGRect { CGRect(x: b.x * W, y: b.y * H, width: b.w * W, height: b.h * H) }
            ctx.setLineWidth(3)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            for f in smp.faces { ctx.stroke(rect(f.box)) }
            ctx.setStrokeColor(NSColor.systemPurple.cgColor)
            for p in smp.people { ctx.stroke(rect(p)) }
            if let k, shot.subjects.indices.contains(k), let sub = shot.subjects[k] {
                ctx.setStrokeColor(NSColor.systemGreen.cgColor); ctx.setLineWidth(5); ctx.stroke(rect(sub))
            }
            if shot.mode == .track, let k, shot.keys.indices.contains(k) {
                let cw = plan.cropWidth / shot.zoom
                ctx.setStrokeColor(NSColor.systemYellow.cgColor); ctx.setLineWidth(6)
                ctx.stroke(CGRect(x: (shot.keys[k] - cw / 2) * W, y: shot.top * H, width: cw * W, height: H / shot.zoom))
                ctx.setFillColor(NSColor.red.withAlphaComponent(0.25).cgColor)   // caption / platform-UI zone of the crop
                ctx.fill(CGRect(x: (shot.keys[k] - cw / 2) * W, y: (shot.top + captionZone / shot.zoom) * H, width: cw * W, height: H * (1 - captionZone) / shot.zoom))
            }
            let label = "shot \((plan.shots.firstIndex { $0.start == shot.start } ?? 0) + 1) · \(shot.mode == .fill ? "BLUR FILL" : "TRACK") · \(shot.reason)"
                + (abs(smp.t - shot.start) < step ? "  ✂︎ CUT" : "")
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.white,
                                                           .backgroundColor: NSColor.black.withAlphaComponent(0.6)]).draw(at: CGPoint(x: 16, y: 12))
            NSGraphicsContext.restoreGraphicsState()
            let f = dir.appendingPathComponent(String(format: "d%05d.png", i))
            try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: f)
            let d = i + 1 < plan.samples.count ? plan.samples[i + 1].t - smp.t : max(0.05, duration - smp.t)
            list += "file '\(f.lastPathComponent)'\nduration \(String(format: "%.3f", d))\n"
            last = f.lastPathComponent
        }
        list += "file '\(last)'\n"
        let url = dir.appendingPathComponent("debug.ffconcat")
        try list.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
