import AVFoundation
import CryptoKit
import Foundation
import ImageIO

/// Imports a folder / files: reads capture date, GPS, duration, size and orientation, sorts chronologically,
/// and makes 540p proxies for fast analysis (resumable: existing proxies are reused).
enum FootageImporter {
    static let videoTypes: Set<String> = ["mp4", "mov", "m4v", "mkv"]
    static let photoTypes: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]

    /// Expands folders (recursively) into supported files.
    static func files(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL { if isSupported(f) { out.append(f) } }
            } else if isSupported(u) { out.append(u) }
        }
        return Array(Set(out)).sorted { $0.path < $1.path }
    }

    static func isSupported(_ u: URL) -> Bool { let e = u.pathExtension.lowercased(); return videoTypes.contains(e) || photoTypes.contains(e) }

    static func fingerprint(_ u: URL) -> String {
        let a = (try? FileManager.default.attributesOfItem(atPath: u.path)) ?? [:]
        let s = "\(u.path)|\((a[.size] as? NSNumber)?.int64Value ?? 0)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func metadata(_ u: URL) async throws -> VlogAsset {
        let id = fingerprint(u)
        let fileDate = ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.creationDate] as? Date) ?? .now
        if photoTypes.contains(u.pathExtension.lowercased()) {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { throw ClipForgeError("Can't read photo \(u.lastPathComponent).") }
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            let date = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(exifDate) ?? fileDate
            var lat = gps?[kCGImagePropertyGPSLatitude] as? Double, lon = gps?[kCGImagePropertyGPSLongitude] as? Double
            if (gps?[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = lat.map { -$0 } }
            if (gps?[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = lon.map { -$0 } }
            let orient = props[kCGImagePropertyOrientation] as? Int ?? 1
            var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            if [5, 6, 7, 8].contains(orient) { swap(&w, &h) }
            return VlogAsset(id: id, path: u.path, isPhoto: true, captured: date, latitude: lat, longitude: lon, duration: 0, width: w, height: h, hasAudio: false)
        }
        let asset = AVURLAsset(url: u)
        let duration = try await asset.load(.duration).seconds
        var w = 0, h = 0, hasAudio = false
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (size, t) = try await track.load(.naturalSize, .preferredTransform)
            let r = CGRect(origin: .zero, size: size).applying(t)
            w = Int(abs(r.width)); h = Int(abs(r.height))
        }
        hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        var date = fileDate, lat: Double?, lon: Double?
        if let d = try? await asset.load(.creationDate)?.load(.dateValue) { date = d }
        // Location lives under different keys per device (©xyz, com.apple.quicktime.location.ISO6709, mdta keys):
        // take the first value shaped like an ISO 6709 coordinate.
        for item in try await asset.load(.metadata) where lat == nil {
            if let s = try? await item.load(.stringValue), s.range(of: #"^[+-]\d+(\.\d+)?[+-]\d+(\.\d+)?"#, options: .regularExpression) != nil {
                (lat, lon) = iso6709(s)
            }
        }
        return VlogAsset(id: id, path: u.path, isPhoto: false, captured: date, latitude: lat, longitude: lon, duration: duration, width: w, height: h, hasAudio: hasAudio)
    }

    static func exifDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }

    /// "+15.4909+073.8278+010.000/" → (15.4909, 73.8278)
    static func iso6709(_ s: String) -> (Double?, Double?) {
        let parts = s.replacingOccurrences(of: "/", with: "").split(omittingEmptySubsequences: true) { $0 == "+" || $0 == "-" }
        guard parts.count >= 2 else { return (nil, nil) }
        var signs: [Double] = []
        for ch in s where ch == "+" || ch == "-" { signs.append(ch == "-" ? -1 : 1) }
        guard signs.count >= 2, let a = Double(parts[0]), let b = Double(parts[1]) else { return (nil, nil) }
        return (a * signs[0], b * signs[1])
    }

    /// 540p H.264 proxy for analysis/preview; reused if already there.
    static func proxy(_ a: VlogAsset, dir: URL, ffmpeg: URL) async throws -> String {
        let out = dir.appendingPathComponent("\(a.id).mp4")
        if FileManager.default.fileExists(atPath: out.path) { return out.path }
        let tmp = dir.appendingPathComponent("\(a.id).part.mp4")
        try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", a.path, "-vf", "scale=-2:540",
                                     "-c:v", "h264_videotoolbox", "-b:v", "1500k", "-c:a", "aac", "-b:a", "96k", "-ac", "1", tmp.path])
        try FileManager.default.moveItem(at: tmp, to: out)
        return out.path
    }
}
