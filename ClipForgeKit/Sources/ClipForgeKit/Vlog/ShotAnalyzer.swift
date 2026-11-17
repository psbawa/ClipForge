import CoreLocation
import Foundation
import ImageIO
import Vision

/// Per-file quality + interest analysis on proxies, cached by file fingerprint.
enum ShotAnalyzer {
    // Thresholds (one place).
    static let darkLuma = 0.11, brightLuma = 0.93, coveredLuma = 0.05
    static let blurRelative = 0.35          // sharpness below 35% of the footage median = blurry
    static let shakeLimit = 0.55            // normalized frame-to-frame jitter
    static let minGoodRange = 1.5
    static let duplicateDiff = 10.0         // mean abs diff of 64×36 mean frames
    static let duplicateGap = 300.0         // only takes within 5 min of each other count as near-duplicates

    struct Frame { var luma: Double; var sharp: Double; var diff: Double; var faces: Int }

    static func cacheURL(_ a: VlogAsset, dir: URL) -> URL { dir.appendingPathComponent("\(a.id).json") }

    static func analyze(_ a: VlogAsset, ffmpeg: URL, transcriber: (any Transcribing)?, cache: URL) async throws -> VlogAsset {
        if let d = try? Data(contentsOf: cacheURL(a, dir: cache)), let c = try? JSONDecoder().decode(VlogAsset.self, from: d), c.analyzed { return c }
        var out = a
        if a.isPhoto {
            guard let src = CGImageSourceCreateWithURL(a.url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                        kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            else { throw ClipForgeError("Can't read \(a.name).") }
            let f = frame(img, prev: nil)
            out.brightness = f.luma; out.sharpness = f.sharp
            out.fingerprint = Reframer.thumbnail(img)
            out.score = 35 + 30 * min(1, f.sharp * 4) + Double(min(f.faces, 2)) * 8
            if f.luma < darkLuma { out.rejected = "too dark" } else if f.luma > brightLuma { out.rejected = "overexposed" }
        } else {
            guard let proxy = a.proxyPath else { throw ClipForgeError("No proxy for \(a.name).") }
            let dir = cache.appendingPathComponent("frames-\(a.id)")
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-i", proxy, "-vf", "fps=2,scale=320:-2", dir.appendingPathComponent("f%05d.jpg").path])
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
            var frames: [Frame] = [], prev: [UInt8]?, mean = [Double](repeating: 0, count: Reframer.thumbW * Reframer.thumbH)
            for (i, f) in files.enumerated() {
                guard let s = CGImageSourceCreateWithURL(f as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { continue }
                let g = Reframer.thumbnail(img)
                var fr = frame(img, prev: prev, faces: i % 4 == 0)
                fr.diff = prev.map { p in Double(zip(p, g).map { abs(Int($0) - Int($1)) }.reduce(0, +)) / Double(g.count) / 255 } ?? 0
                frames.append(fr)
                for k in mean.indices { mean[k] += Double(g[k]) }
                prev = g
            }
            out.fingerprint = mean.map { UInt8(min(255, $0 / Double(max(files.count, 1)))) }
            if a.hasAudio, let transcriber {
                out.words = (try? await transcriber.transcribe(MediaSegment(url: URL(fileURLWithPath: proxy), start: 0, end: a.duration), progress: nil)) ?? []
            }
            let faceShare = Double(frames.filter { $0.faces > 0 }.count) / Double(max(frames.filter { $0.faces >= 0 }.count, 1))  // faces checked on every 4th frame
            out.talking = Double(out.words.count) / max(a.duration, 1) > 1.0 && faceShare > 0.3
            (out.goodRanges, out.rejected) = goodRanges(frames, fps: 2, duration: a.duration, talking: out.talking)
            out.brightness = frames.map(\.luma).reduce(0, +) / Double(max(frames.count, 1))
            out.sharpness = frames.map(\.sharp).sorted().dropFirst(frames.count / 2).first ?? 0
            out.shake = jitter(frames)
            let motion = frames.map(\.diff).reduce(0, +) / Double(max(frames.count, 1))
            out.score = 30 + 25 * min(1, out.sharpness * 4) + 20 * min(1, motion * 12) + (out.talking ? 20 : 0) + 5 * min(1, faceShare)
        }
        out.analyzed = true
        try? JSONEncoder().encode(out).write(to: cacheURL(a, dir: cache))
        return out
    }

    /// Luma, sharpness (Laplacian variance on a small gray image) and optionally face count.
    static func frame(_ img: CGImage, prev: [UInt8]?, faces: Bool = true) -> Frame {
        let w = 160, h = 90
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let luma = Double(px.reduce(0) { $0 + Int($1) }) / Double(px.count) / 255
        var lap: [Double] = []
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let c = Int(px[y * w + x]) * 4 - Int(px[y * w + x - 1]) - Int(px[y * w + x + 1]) - Int(px[(y - 1) * w + x]) - Int(px[(y + 1) * w + x])
            lap.append(Double(c))
        } }
        let m = lap.reduce(0, +) / Double(lap.count)
        let variance = lap.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(lap.count)
        var n = -1
        if faces {
            let r = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: img).perform([r])
            n = r.results?.count ?? 0
        }
        return Frame(luma: luma, sharp: min(1, sqrt(variance) / 255), diff: 0, faces: n)
    }

    /// Frame-to-frame jitter: rapid alternation in motion (handheld shake), not steady motion.
    static func jitter(_ f: [Frame]) -> Double {
        guard f.count > 3 else { return 0 }
        let d = f.map(\.diff)
        let alt = zip(d.dropFirst(), d).map { abs($0 - $1) }.reduce(0, +) / Double(d.count - 1)
        return min(1, alt * 15)
    }

    /// Usable sub-ranges and, if none, why the shot is rejected. Talking segments are kept whole unless unusable.
    static func goodRanges(_ f: [Frame], fps: Double, duration: Double, talking: Bool) -> ([[Double]], String?) {
        guard !f.isEmpty else { return ([], "unreadable") }
        let medSharp = f.map(\.sharp).sorted()[f.count / 2]
        var reasons: [String: Int] = [:]
        let ok = f.enumerated().map { i, x -> Bool in
            if x.luma < coveredLuma { reasons["lens covered / pocket shot", default: 0] += 1; return false }
            if x.luma < darkLuma { reasons["too dark", default: 0] += 1; return false }
            if x.luma > brightLuma { reasons["overexposed", default: 0] += 1; return false }
            if x.sharp < max(0.015, medSharp * blurRelative), !talking { reasons["blurry", default: 0] += 1; return false }
            let local = f[max(0, i - 2)...min(f.count - 1, i + 2)].map(\.diff)
            let jit = zip(local.dropFirst(), local).map { abs($0 - $1) }.reduce(0, +) / Double(max(local.count - 1, 1))
            if jit * 15 > shakeLimit * 1.6, !talking { reasons["too shaky", default: 0] += 1; return false }
            return true
        }
        var ranges: [[Double]] = [], start: Int?
        for (i, good) in ok.enumerated() + [(ok.count, false)] {
            if good, start == nil { start = i }
            if !good, let s = start {
                let a = Double(s) / fps, b = min(duration, Double(i) / fps)
                if b - a >= minGoodRange { ranges.append([a, b]) }
                start = nil
            }
        }
        if ranges.isEmpty { return ([], reasons.max { $0.value < $1.value }?.key ?? "too short") }
        return (ranges, nil)
    }

    /// Near-duplicate takes close in time: keep the better one.
    static func markDuplicates(_ assets: inout [VlogAsset]) {
        let order = assets.indices.sorted { assets[$0].captured < assets[$1].captured }
        for (k, i) in order.enumerated() where assets[i].rejected == nil {
            for j in order.dropFirst(k + 1) {
                guard assets[j].captured.timeIntervalSince(assets[i].captured) < duplicateGap else { break }
                guard assets[j].rejected == nil, assets[i].isPhoto == assets[j].isPhoto,
                      assets[i].fingerprint.count == assets[j].fingerprint.count, !assets[i].fingerprint.isEmpty else { continue }
                let diff = Double(zip(assets[i].fingerprint, assets[j].fingerprint).map { abs(Int($0) - Int($1)) }.reduce(0, +)) / Double(assets[i].fingerprint.count)
                if diff < duplicateDiff {
                    let (keep, drop) = assets[i].score >= assets[j].score ? (i, j) : (j, i)
                    assets[drop].rejected = "near-duplicate of \(assets[keep].name)"
                    assets[drop].duplicateOf = assets[keep].id
                }
            }
        }
    }
}

enum ChapterBuilder {
    static let maxGap = 90.0 * 60      // new chapter after 90 min without footage
    static let maxDistanceKm = 3.0

    static func km(_ a: VlogAsset, _ b: VlogAsset) -> Double? {
        guard let la = a.latitude, let lo = a.longitude, let lb = b.latitude, let lob = b.longitude else { return nil }
        let r = 6371.0, dLat = (lb - la) * .pi / 180, dLon = (lob - lo) * .pi / 180
        let x = sin(dLat / 2) * sin(dLat / 2) + cos(la * .pi / 180) * cos(lb * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(x), sqrt(1 - x))
    }

    /// Chronological groups split by day, time gaps and distance. Pure (no geocoding); unit-tested.
    static func group(_ assets: [VlogAsset]) -> [VlogChapter] {
        let usable = assets.filter { $0.rejected == nil }.sorted { $0.captured < $1.captured }
        guard let first = usable.first else { return [] }
        let cal = Calendar.current
        var chapters: [VlogChapter] = [], cur = [first], dayIndex = 1
        func close() {
            let day = cal.dateComponents([.day], from: cal.startOfDay(for: first.captured), to: cal.startOfDay(for: cur[0].captured)).day ?? 0
            dayIndex = day + 1
            // Files without capture dates fall back to the file date (often today): label those by date, not "Day 262".
            let title = dayIndex <= 30 ? "Day \(dayIndex)" : cur[0].captured.formatted(.dateTime.month(.abbreviated).day())
            chapters.append(VlogChapter(index: chapters.count, title: title, place: nil, start: cur.first!.captured,
                                        end: cur.last!.captured.addingTimeInterval(cur.last!.duration), assetIDs: cur.map(\.id)))
        }
        for a in usable.dropFirst() {
            let prev = cur.last!
            let gap = a.captured.timeIntervalSince(prev.captured.addingTimeInterval(prev.duration))
            let far = km(prev, a).map { $0 > maxDistanceKm } ?? false
            if gap > maxGap || far || !cal.isDate(a.captured, inSameDayAs: prev.captured) { close(); cur = [a] } else { cur.append(a) }
        }
        close()
        return chapters
    }

    /// Place names: one lookup per chapter (CLGeocoder is rate-limited), failures ignored.
    @MainActor static func name(_ chapters: inout [VlogChapter], assets: [VlogAsset]) async {
        let geocoder = CLGeocoder()
        for i in chapters.indices {
            guard let a = assets.first(where: { chapters[i].assetIDs.contains($0.id) && $0.latitude != nil }) else { continue }
            if let p = try? await geocoder.reverseGeocodeLocation(CLLocation(latitude: a.latitude!, longitude: a.longitude!)).first {
                chapters[i].place = p.locality ?? p.name ?? p.administrativeArea
                if let place = chapters[i].place { chapters[i].title = "\(chapters[i].title) · \(place)" }
            }
            try? await Task.sleep(for: .milliseconds(1200))
        }
    }
}
