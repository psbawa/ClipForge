import CoreImage
import Foundation
import ImageIO
import Vision

/// "Edit like this": measures a reference video the user has rights to analyze (locally) and turns the
/// measurements into a custom style profile with Claude.
enum ReferenceAnalyzer {
    struct Metrics: Codable, Sendable {
        var duration: Double
        var cuts: Int
        var avgShotSeconds: Double
        var captionFrameShare: Double     // share of frames with on-screen text in the caption area
        var captionTextHeight: Double     // fraction of frame height
        var uppercaseShare: Double
        var wordsPerCard: Double
        var captionPosition: String       // upper / middle / lower
        var punchInsPer10s: Double
        var brightness: Double, saturation: Double, contrast: Double
        var loudnessLUFS: Double
        var bpm: Double?
    }

    static func analyze(_ video: URL, ffmpeg: URL, work: URL) async throws -> Metrics {
        let (duration, hasAudio) = try await StoryAnalyzer.probe(video, ffmpeg: ffmpeg)
        let sig = try await StoryAnalyzer.signals(video, duration: duration, hasAudio: hasAudio, ffmpeg: ffmpeg, work: work)
        let cuts = sig.scene.filter { $0 >= editCutScore }.count
        // Frames at 2 fps for text + zoom + color.
        let dir = work.appendingPathComponent("ref-frames")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-t", "180", "-i", video.path, "-vf", "fps=2,scale=480:-2", dir.appendingPathComponent("f%05d.jpg").path])
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        var textFrames = 0, heights: [Double] = [], ys: [Double] = [], upper = 0, letters = 0, words: [Int] = []
        var bright: [Double] = [], sat: [Double] = [], contrast: [Double] = []
        let ci = CIContext()
        for f in files {
            guard let src = CGImageSourceCreateWithURL(f as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .fast
            try? VNImageRequestHandler(cgImage: img).perform([req])
            let obs = (req.results ?? []).filter { $0.boundingBox.height > 0.025 && $0.confidence > 0.4 }
            if !obs.isEmpty {
                textFrames += 1
                for o in obs {
                    heights.append(o.boundingBox.height); ys.append(1 - o.boundingBox.midY)
                    let s = o.topCandidates(1).first?.string ?? ""
                    words.append(s.split(separator: " ").count)
                    for ch in s where ch.isLetter { letters += 1; if ch.isUppercase { upper += 1 } }
                }
            }
            let g = Reframer.thumbnail(img)
            let mean = Double(g.reduce(0) { $0 + Int($1) }) / Double(g.count)
            contrast.append(sqrt(g.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(g.count)) / 255)
            let avg = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: CIImage(cgImage: img), kCIInputExtentKey: CIVector(cgRect: CGRect(x: 0, y: 0, width: img.width, height: img.height))])!
            var px = [UInt8](repeating: 0, count: 4)
            ci.render(avg.outputImage!, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            let (r, gg, b) = (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
            let mx = max(r, gg, b), mn = min(r, gg, b)
            bright.append(mx); sat.append(mx > 0 ? (mx - mn) / mx : 0)
        }
        let analyzed = Double(files.count) / 2
        let zooms = try await punchIns(video, ffmpeg: ffmpeg, work: work)
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        let y = avg(ys)
        var bpm: Double?
        if hasAudio, let beats = try? await MusicLibrary.beats(video, ffmpeg: ffmpeg), beats.count > 8 {
            let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
            bpm = 60 / gaps[gaps.count / 2]
        }
        return Metrics(duration: duration, cuts: cuts, avgShotSeconds: duration / Double(cuts + 1),
                       captionFrameShare: files.isEmpty ? 0 : Double(textFrames) / Double(files.count), captionTextHeight: avg(heights),
                       uppercaseShare: letters == 0 ? 0 : Double(upper) / Double(letters), wordsPerCard: avg(words.map(Double.init)),
                       captionPosition: y < 0.38 ? "upper" : y < 0.66 ? "middle" : "lower",
                       punchInsPer10s: analyzed > 0 ? Double(zooms) / analyzed * 10 : 0,
                       brightness: avg(bright), saturation: avg(sat), contrast: avg(contrast),
                       loudnessLUFS: avg(sig.loudness.filter { $0 > -69 }), bpm: bpm)
    }

    /// Punch-ins start at a cut and ramp in ~0.4 s, so 2 fps samples straddle the cut and never match.
    /// Separate cheap pass: 5 fps gray thumbnails, frame i vs i-2 (0.4 s, same shot), one count per ramp.
    static func punchIns(_ video: URL, ffmpeg: URL, work: URL) async throws -> Int {
        let w = Reframer.thumbW, h = Reframer.thumbH
        let raw = work.appendingPathComponent("ref-zoom.gray")
        try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-t", "180", "-i", video.path,
                                     "-vf", "fps=5,scale=\(w):\(h),format=gray", "-f", "rawvideo", raw.path])
        let bytes = [UInt8]((try? Data(contentsOf: raw)) ?? Data())
        try? FileManager.default.removeItem(at: raw)
        let frames = stride(from: 0, to: bytes.count - w * h + 1, by: w * h).map { Array(bytes[$0..<$0 + w * h]) }
        var count = 0, last = -10
        for i in frames.indices.dropFirst(2) where zoomedIn(frames[i - 2], frames[i]) {
            if i - last > 3 { count += 1 }
            last = i
        }
        return count
    }

    /// Cuts in a finished edit (flash/whip transitions blend frames) score far lower than the big moments
    /// SelectionConfig.sceneCutScore looks for in raw footage; 8 matched 15 known cuts in a real gaming edit.
    static let editCutScore = 8.0

    /// Did frame b zoom into frame a? Compare b with centre crops of a at the usual punch-in scales.
    static func zoomedIn(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let w = Reframer.thumbW, h = Reframer.thumbH
        func at(_ x: Int, _ y: Int, _ img: [UInt8]) -> Int { Int(img[min(h - 1, max(0, y)) * w + min(w - 1, max(0, x))]) }
        func diff(_ s: Double) -> Double {
            var d = 0
            for y in 0..<h { for x in 0..<w {
                let zx = Int(Double(w) / 2 + (Double(x) - Double(w) / 2) / s), zy = Int(Double(h) / 2 + (Double(y) - Double(h) / 2) / s)
                d += abs(at(x, y, b) - at(zx, zy, a))
            } }
            return Double(d) / Double(w * h)
        }
        let plain = diff(1)
        return plain > 6 && [1.05, 1.1, 1.15, 1.2].map(diff).min()! < plain * 0.7
    }

    static func profile(_ m: Metrics, name: String, client: LLMClient, cost: CostTracker, settings: AppSettings) async throws -> StyleProfile {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let example = StyleLibrary.profile("gaming-fast").map { String(decoding: (try? enc.encode($0)) ?? Data(), as: UTF8.self) } ?? ""
        let user = """
        Reference video measurements:
        \(String(decoding: try enc.encode(m), as: UTF8.self))

        Schema example (another profile):
        \(example)

        Create a profile named "\(name)" that reproduces this reference's editing style.
        """
        guard await cost.canSpend(budget: settings.dailyBudgetUSD) else { throw HighlightError.budgetReached }
        let r = try await client.complete(model: TrendRefresh.model, system: """
            You turn measured editing metrics of a reference video into an editing style profile. Map: avgShotSeconds → pacing,
            punch-ins → motion (punchInsPer10s is a lower bound: camera motion in fast footage hides zooms, so 0 means "none detected", not "none"; lean on pacing and genre), caption metrics → captions (style pop for big bold uppercase, boxed for text on a box, clean otherwise;
            animation "pop" for fast word-by-word), loudness/bpm → music energy and mood, brightness/saturation/contrast → color
            (punchy / cinematic / warm / cool / muted / neutral). Explain the mapping briefly in "notes". Output ONLY the JSON object.
            """, user: user, maxTokens: 4000, effort: "medium")
        await cost.record(r.usage, price: settings.prices[TrendRefresh.model])
        guard let a = r.text.firstIndex(of: "{"), let b = r.text.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(r.text[a...b].utf8)),
              let base = StyleLibrary.profile("gaming-fast"), var p = StyleLibrary.merge(base, patch: json) else {
            throw ClipForgeError("Couldn't turn the reference into a style (Claude's answer wasn't usable JSON). Try again.")
        }
        p.summary = ((json as? [String: Any])?["summary"] as? String) ?? "Learned from a reference video."
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        p.id = "ref-" + String(slug).split(separator: "-").joined(separator: "-")
        p.name = name
        p.version = StyleLibrary.today
        p.origin = "reference"
        return p
    }
}
