import Foundation

/// A piece of recorded media placed on the session timeline.
public struct MediaSegment: Sendable, Hashable, Codable {
    public var url: URL
    public var start: Double
    public var end: Double
    public init(url: URL, start: Double, end: Double) { self.url = url; self.start = start; self.end = end }
}

public struct SourceInfo: Sendable, Equatable {
    public var title: String
    public var channelID: String
    public var channelName: String
    public var isLive: Bool
    public var duration: Double?
}

public protocol Ingesting: Actor {
    func probe(_ url: String) async throws -> SourceInfo
    func downloadVOD(_ url: String, into dir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaSegment
    /// Yields 10 s segments as they land; reconnects on drops until `stopLive()`.
    func startLive(_ url: String, into dir: URL, bufferMinutes: Double) -> AsyncStream<MediaSegment>
    func stopLive()
    /// Segments still on disk that overlap [from, to].
    func segments(from: Double, to: Double) -> [MediaSegment]
}

public actor IngestService: Ingesting {
    let bin: Binaries
    var buffer: [MediaSegment] = []
    var liveTask: Task<Void, Never>?
    var procs: [Process] = []

    public init(binaries: Binaries) { bin = binaries }

    public func probe(_ url: String) async throws -> SourceInfo {
        let json = try await Shell.run(bin.ytdlp, ["--dump-single-json", "--skip-download", "--no-playlist", "--no-warnings", url])
        guard let o = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ClipForgeError("Could not read video info from yt-dlp")
        }
        return SourceInfo(title: o["title"] as? String ?? url,
                          channelID: o["channel_id"] as? String ?? "",
                          channelName: o["channel"] as? String ?? o["uploader"] as? String ?? "",
                          isLive: o["is_live"] as? Bool ?? false,
                          duration: o["duration"] as? Double)
    }

    public func downloadVOD(_ url: String, into dir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaSegment {
        let out = dir.appendingPathComponent("source.mp4")
        if !FileManager.default.fileExists(atPath: out.path) {
            try await Shell.stream(bin.ytdlp, [
                "-f", "bv*[height<=1080][ext=mp4]+ba[ext=m4a]/b[height<=1080]/b", "--merge-output-format", "mp4",
                "--no-playlist", "--no-part", "--newline", "--no-warnings",
                "--progress-template", "download:%(progress._percent_str)s", "-o", out.path, url,
            ]) { line in
                if let p = Double(line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) { progress(p / 100) }
            }
        }
        let dur = try await Self.duration(of: out, ffmpeg: bin.ffmpeg)
        let seg = MediaSegment(url: out, start: 0, end: dur)
        buffer = [seg]
        return seg
    }

    public func startLive(_ url: String, into dir: URL, bufferMinutes: Double) -> AsyncStream<MediaSegment> {
        let (stream, cont) = AsyncStream.makeStream(of: MediaSegment.self)
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            await self?.liveLoop(url, dir: dir, retention: bufferMinutes * 60, cont: cont)
            cont.finish()
        }
        return stream
    }

    public func stopLive() {
        liveTask?.cancel()
        liveTask = nil
        procs.forEach { $0.terminate() }
        procs = []
    }

    public func segments(from: Double, to: Double) -> [MediaSegment] {
        buffer.filter { $0.end > from && $0.start < to && FileManager.default.fileExists(atPath: $0.url.path) }
    }

    // MARK: live internals

    func liveLoop(_ url: String, dir: URL, retention: Double, cont: AsyncStream<MediaSegment>.Continuation) async {
        var backoff: UInt64 = 2
        var nextIndex = 0
        var failures = 0
        // ~4 minutes of failed reconnects with no new segments = the stream is over.
        while !Task.isCancelled, failures < 8 {
            let runOffset = buffer.last?.end ?? 0
            let list = dir.appendingPathComponent("index-\(nextIndex).csv")
            do {
                let (yt, ff) = try launchCapture(url, dir: dir, list: list, startNumber: nextIndex)
                var seen = 0, clock = runOffset
                while ff.isRunning, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    // CSV rows: filename,start,end — append-only, a row means the segment is complete.
                    let rows = ((try? String(contentsOf: list, encoding: .utf8)) ?? "").split(separator: "\n")
                    for row in rows.dropFirst(seen) {
                        let f = row.split(separator: ",")
                        guard f.count >= 3, let s = Double(f[1]), let e = Double(f[2]) else { continue }
                        let seg = MediaSegment(url: dir.appendingPathComponent(String(f[0])), start: clock, end: clock + (e - s))
                        clock = seg.end
                        buffer.append(seg)
                        nextIndex += 1
                        backoff = 2
                        failures = 0
                        cont.yield(seg)
                    }
                    seen = rows.count
                    prune(olderThan: clock - retention)
                }
                yt.terminate(); ff.terminate()
                if Task.isCancelled { break }
                Log.ingest.warning("Live capture ended; reconnecting in \(backoff)s")
            } catch {
                Log.ingest.error("Live capture failed to start: \(error.localizedDescription, privacy: .private)")
            }
            failures += 1
            try? await Task.sleep(for: .seconds(Double(backoff)))
            backoff = min(backoff * 2, 60)
        }
    }

    func launchCapture(_ url: String, dir: URL, list: URL, startNumber: Int) throws -> (Process, Process) {
        let yt = Process(), ff = Process(), pipe = Pipe()
        yt.executableURL = bin.ytdlp
        yt.arguments = ["-f", "best[height<=1080]/best", "--no-part", "--quiet", "--no-warnings", "-o", "-", url]
        yt.environment = Shell.env
        yt.standardOutput = pipe
        yt.standardError = FileHandle.nullDevice
        ff.executableURL = bin.ffmpeg
        ff.arguments = ["-hide_banner", "-loglevel", "error", "-i", "pipe:0", "-map", "0:v:0?", "-map", "0:a:0?", "-c", "copy",
                        "-f", "segment", "-segment_time", "10", "-reset_timestamps", "1",
                        "-segment_list", list.path, "-segment_list_type", "csv", "-segment_list_flags", "+live",
                        "-segment_start_number", "\(startNumber)", dir.appendingPathComponent("seg_%06d.ts").path]
        ff.standardInput = pipe
        ff.standardError = FileHandle.nullDevice
        try ff.run()
        try yt.run()
        procs = [yt, ff]
        return (yt, ff)
    }

    func prune(olderThan cutoff: Double) {
        let (old, keep) = (buffer.filter { $0.end < cutoff }, buffer.filter { $0.end >= cutoff })
        for s in old { try? FileManager.default.removeItem(at: s.url) }
        buffer = keep
    }

    static func duration(of url: URL, ffmpeg: URL) async throws -> Double {
        // `ffmpeg -i` prints "Duration: HH:MM:SS.ss" to stderr and exits 1; parse it from the error.
        do { try await Shell.run(ffmpeg, ["-hide_banner", "-i", url.path]) } catch let e as ClipForgeError {
            if let r = e.message.range(of: #"Duration: (\d+):(\d+):(\d+\.?\d*)"#, options: .regularExpression) {
                let p = e.message[r].dropFirst(10).split(separator: ":").compactMap { Double($0) }
                if p.count == 3 { return p[0] * 3600 + p[1] * 60 + p[2] }
            }
        }
        throw ClipForgeError("Could not read media duration")
    }
}

extension Shell {
    /// Runs a process, calling `onLine` for each stdout line.
    static func stream(_ exe: URL, _ args: [String], onLine: @escaping @Sendable (String) -> Void) async throws {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                p.terminationHandler = { p in
                    p.terminationStatus == 0 ? c.resume() : c.resume(throwing: ClipForgeError("\(exe.lastPathComponent) exited with \(p.terminationStatus)"))
                }
                do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: error); return }
                Task.detached {
                    do { for try await line in out.fileHandleForReading.bytes.lines { onLine(line) } } catch {}
                }
            }
        } onCancel: { p.terminate() }
    }
}
