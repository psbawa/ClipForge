import Foundation
import SoundAnalysis
import Vision

/// Something that happened in the game at a moment in time: HUD text or an audio event.
struct GameEvent: Codable, Sendable, Hashable {
    enum Source: String, Codable, Sendable { case hud, audio }
    var time: Double
    var source: Source
    var label: String          // "VICTORY", "gunshot_gunfire", …
    var weight: Double
}

/// Per-genre tuning: what HUD text and which sounds count as a moment, and how the selection signals are weighted.
public struct GenreProfile: Sendable {
    public let id: String
    public let label: String
    let hud: [String: Double]          // uppercase keyword → weight (counted when it newly appears)
    let audio: [String: Double]        // SoundAnalysis class → weight
    let weights: [(key: String, weight: Double)]
}

public enum GenreConfig {
    static let audioConfidence = 0.5
    static let ocrWorkers = 6
    static let popupWeight = 0.4       // "+100"-style score popups
    /// Every event class's weight is multiplied by this before it joins the per-second "hud"/"events" signals.
    static let shared: [String: Double] = ["VICTORY": 2, "WINNER": 2, "WIN": 1, "NEW RECORD": 1.5, "LEVEL UP": 0.8, "ACHIEVEMENT": 0.8]

    public static let all: [GenreProfile] = [
        GenreProfile(id: "fps", label: "Shooter / battle royale",
                     hud: shared.merging(["ELIMINATED": 1, "ELIMINATION": 1, "HEADSHOT": 1, "DOUBLE KILL": 1.5, "TRIPLE KILL": 2, "MULTI KILL": 2,
                                          "SQUAD WIPED": 1.5, "TEAM WIPED": 1.5, "KNOCKED": 0.6, "DOWNED": 0.6, "KILLSTREAK": 1.2, "#1": 1.5, "CHAMPION": 2]) { $1 },
                     audio: ["gunshot_gunfire": 0.6, "boom": 1, "glass_breaking": 0.4, "shout": 0.5, "yell": 0.5, "screaming": 0.6, "cheering": 0.8, "laughter": 0.6],
                     weights: [("loudness", 0.05), ("audioPeak", 0.15), ("motion", 0.10), ("scenes", 0.05), ("speech", 0.05),
                               ("transcript", 0.20), ("hud", 0.20), ("events", 0.20), ("watch", 0.30)]),
        GenreProfile(id: "sports", label: "Sports",
                     hud: shared.merging(["GOAL": 2, "TOUCHDOWN": 2, "HOME RUN": 2, "SLAM DUNK": 1.5, "PENALTY": 1, "RED CARD": 1.2, "FULL TIME": 0.8]) { $1 },
                     audio: ["cheering": 1, "crowd": 0.6, "applause": 0.8, "shout": 0.5, "yell": 0.5],
                     weights: [("loudness", 0.10), ("audioPeak", 0.15), ("motion", 0.05), ("scenes", 0.05), ("speech", 0.05),
                               ("transcript", 0.20), ("hud", 0.20), ("events", 0.20), ("watch", 0.30)]),
        GenreProfile(id: "racing", label: "Racing",
                     hud: shared.merging(["1ST": 1.5, "OVERTAKE": 1, "FASTEST LAP": 1.5, "FINAL LAP": 1, "NEW LAP RECORD": 1.5, "WRECKED": 1]) { $1 },
                     audio: ["race_car": 0.3, "engine_accelerating_revving": 0.3, "boom": 1, "glass_breaking": 0.8, "screaming": 0.5, "cheering": 0.8],
                     weights: [("loudness", 0.10), ("audioPeak", 0.15), ("motion", 0.15), ("scenes", 0.05), ("speech", 0.05),
                               ("transcript", 0.15), ("hud", 0.15), ("events", 0.20), ("watch", 0.30)]),
        GenreProfile(id: "fighting", label: "Fighting",
                     hud: shared.merging(["K.O.": 2, "KO": 2, "PERFECT": 2, "FATALITY": 2, "COMBO": 1, "ROUND": 0.5]) { $1 },
                     audio: ["shout": 0.6, "yell": 0.6, "screaming": 0.6, "boom": 0.6, "cheering": 0.8],
                     weights: [("loudness", 0.05), ("audioPeak", 0.15), ("motion", 0.15), ("scenes", 0.05), ("speech", 0.05),
                               ("transcript", 0.15), ("hud", 0.20), ("events", 0.20), ("watch", 0.30)]),
        GenreProfile(id: "horror", label: "Horror",
                     hud: shared.merging(["YOU DIED": 1.5, "GAME OVER": 1.2]) { $1 },
                     audio: ["screaming": 1.5, "gasp": 1, "shout": 0.8, "yell": 0.8, "boom": 0.6, "glass_breaking": 0.6, "laughter": 0.6],
                     weights: [("loudness", 0.05), ("audioPeak", 0.25), ("motion", 0.05), ("scenes", 0.05), ("speech", 0.05),
                               ("transcript", 0.25), ("hud", 0.05), ("events", 0.25), ("watch", 0.30)]),
        GenreProfile(id: "other", label: "Other / mixed",
                     hud: shared.merging(["GAME OVER": 0.8, "MISSION COMPLETE": 1, "BOSS": 0.6, "DEFEATED": 1]) { $1 },
                     audio: ["boom": 0.6, "screaming": 0.6, "shout": 0.5, "yell": 0.5, "laughter": 0.6, "cheering": 0.8, "gasp": 0.5],
                     weights: [("loudness", 0.10), ("audioPeak", 0.15), ("motion", 0.10), ("scenes", 0.05), ("speech", 0.10),
                               ("transcript", 0.30), ("hud", 0.10), ("events", 0.10), ("watch", 0.30)]),
    ]
    public static func profile(_ id: String) -> GenreProfile { all.first { $0.id == id } ?? all.last! }

    /// Guess the genre from how often each sound appears (share of seconds with a confident detection).
    static func detect(audioSeconds share: [String: Double], hudHits: [String: Int]) -> GenreProfile {
        if share["gunshot_gunfire", default: 0] > 0.04 { return profile("fps") }
        if share["race_car", default: 0] + share["engine_accelerating_revving", default: 0] > 0.10 { return profile("racing") }
        if hudHits["GOAL", default: 0] + hudHits["TOUCHDOWN", default: 0] > 0 || share["crowd", default: 0] > 0.15 { return profile("sports") }
        if hudHits["K.O.", default: 0] + hudHits["KO", default: 0] + hudHits["FATALITY", default: 0] > 0 { return profile("fighting") }
        if share["screaming", default: 0] > 0.02 { return profile("horror") }
        return profile("other")
    }
}

enum GameplayScanner {
    /// Raw detections, before genre weights are applied (so genre can be auto-detected from them).
    struct Scan: Codable, Sendable {
        var hud: [(time: Double, text: String)] = []
        var audio: [(time: Double, label: String, confidence: Double)] = []
        var duration: Double = 0
        enum CodingKeys: CodingKey { case hudT, hudS, audT, audL, audC, duration }
        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            hud = zip(try c.decode([Double].self, forKey: .hudT), try c.decode([String].self, forKey: .hudS)).map { ($0, $1) }
            let t = try c.decode([Double].self, forKey: .audT), l = try c.decode([String].self, forKey: .audL), cf = try c.decode([Double].self, forKey: .audC)
            audio = t.indices.map { (t[$0], l[$0], cf[$0]) }
            duration = try c.decode(Double.self, forKey: .duration)
        }
        func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(hud.map(\.time), forKey: .hudT); try c.encode(hud.map(\.text), forKey: .hudS)
            try c.encode(audio.map(\.time), forKey: .audT); try c.encode(audio.map(\.label), forKey: .audL); try c.encode(audio.map(\.confidence), forKey: .audC)
            try c.encode(duration, forKey: .duration)
        }
    }

    /// HUD text (Vision OCR over the scan's 1 fps frames, in parallel) + sound classes (SoundAnalysis on the scan's WAV).
    /// Local, no API cost, no extra decoding. Cached.
    static func scan(_ v: VideoScan, work: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Scan {
        let cache = work.appendingPathComponent("gameplay-scan.json")
        if let d = try? Data(contentsOf: cache), let s = try? JSONDecoder().decode(Scan.self, from: d), abs(s.duration - v.duration) < 1 { return s }
        var out = Scan(); out.duration = v.duration
        if let wav = v.wav { out.audio = try await classify(wav) }
        progress?(0.2)
        let files = ((try? FileManager.default.contentsOfDirectory(at: v.frames ?? URL(fileURLWithPath: "/nonexistent"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jpg" }.sorted { $0.path < $1.path }
        let slices = GenreConfig.ocrWorkers
        let found = try await withThrowingTaskGroup(of: [(time: Double, text: String)].self) { g in
            for k in 0..<slices {
                g.addTask {
                    var hits: [(time: Double, text: String)] = []
                    for (i, f) in files.enumerated() where i % slices == k {
                        try Task.checkCancellation()
                        let req = VNRecognizeTextRequest()
                        req.recognitionLevel = .fast
                        req.usesLanguageCorrection = false
                        try? VNImageRequestHandler(url: f).perform([req])
                        let t = Double(Int(f.deletingPathExtension().lastPathComponent.dropFirst()) ?? i) + 0.5
                        for o in req.results ?? [] where o.confidence > 0.4 {
                            if let s = o.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces), s.count >= 2 { hits.append((t, s)) }
                        }
                        if k == 0, i % 60 == 0 { progress?(0.2 + 0.8 * Double(i) / Double(max(files.count, 1))) }
                    }
                    return hits
                }
            }
            var all: [(time: Double, text: String)] = []
            for try await h in g { all += h }
            return all.sorted { $0.time < $1.time }
        }
        out.hud = found
        progress?(1)
        try? JSONEncoder().encode(out).write(to: cache)
        return out
    }

    final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        var hits: [(Double, String, Double)] = []
        let wanted: Set<String>
        init(wanted: Set<String>) { self.wanted = wanted }
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            let t = r.timeRange.start.seconds + r.timeRange.duration.seconds / 2
            for c in r.classifications where c.confidence >= GenreConfig.audioConfidence && wanted.contains(c.identifier) {
                hits.append((t, c.identifier, c.confidence))
            }
        }
    }

    static func classify(_ wav: URL) async throws -> [(time: Double, label: String, confidence: Double)] {
        let analyzer = try SNAudioFileAnalyzer(url: wav)
        let req = try SNClassifySoundRequest(classifierIdentifier: .version1)
        req.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 16000)
        req.overlapFactor = 0.5
        let wanted = Set(GenreConfig.all.flatMap { $0.audio.keys } + ["crowd", "race_car", "engine_accelerating_revving"])
        let col = Collector(wanted: wanted)
        try analyzer.add(req, withObserver: col)
        _ = await analyzer.analyze()
        return col.hits.map { ($0.0, $0.1, $0.2) }
    }

    /// Weighted events for a genre. HUD keywords count only when they newly appear (persistent on-screen text
    /// like an objective banner would otherwise fire every second); audio classes merge within 1 s.
    static func events(_ s: Scan, genre g: GenreProfile) -> [GameEvent] {
        var out: [GameEvent] = []
        var lastSeen: [String: Double] = [:]
        let popup = try! NSRegularExpression(pattern: #"^\+\s?\d{2,5}$"#)
        for (t, raw) in s.hud {
            let text = raw.uppercased()
            var matched: [(String, Double)] = g.hud.filter { k, _ in
                k.count <= 3 ? text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "#" && $0 != "." }).contains { String($0) == k } : text.contains(k)
            }.map { ($0.key, $0.value) }
            if popup.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { matched.append(("+POINTS", GenreConfig.popupWeight)) }
            for (k, w) in matched {
                defer { lastSeen[k] = t }
                if let prev = lastSeen[k], t - prev <= 1.5 { continue }   // still on screen
                out.append(GameEvent(time: t, source: .hud, label: k, weight: w))
            }
        }
        var lastAudio: [String: Double] = [:]
        for (t, label, conf) in s.audio.sorted(by: { $0.time < $1.time }) {
            guard let w = g.audio[label] else { continue }
            if let prev = lastAudio[label], t - prev < 1 { continue }
            lastAudio[label] = t
            out.append(GameEvent(time: t, source: .audio, label: label, weight: w * conf))
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Share of seconds with each sound class, and HUD keyword counts — inputs for genre auto-detection.
    static func genre(_ s: Scan, setting: String) -> GenreProfile {
        if setting != "auto" { return GenreConfig.profile(setting) }
        var secs: [String: Set<Int>] = [:]
        for a in s.audio { secs[a.label, default: []].insert(Int(a.time)) }
        let share = secs.mapValues { Double($0.count) / max(s.duration, 1) }
        var hits: [String: Int] = [:]
        for (_, text) in s.hud { for k in ["GOAL", "TOUCHDOWN", "K.O.", "KO", "FATALITY"] where text.uppercased() == k || text.uppercased().contains(k + " ") { hits[k, default: 0] += 1 } }
        return GenreConfig.detect(audioSeconds: share, hudHits: hits)
    }

    /// "12:03 VICTORY · 12:01 gunshot_gunfire ×5" — what the vision model and the review screen see.
    static func summary(_ ev: [GameEvent], from a: Double, to b: Double) -> String {
        let inside = ev.filter { $0.time >= a && $0.time <= b }
        guard !inside.isEmpty else { return "" }
        var groups: [(String, Double, Int)] = []
        for e in inside {
            if let i = groups.lastIndex(where: { $0.0 == e.label && e.time - $0.1 < 10 }) { groups[i].2 += 1 } else { groups.append((e.label, e.time, 1)) }
        }
        return groups.prefix(12).map { String(format: "%d:%02d ", Int($0.1) / 60, Int($0.1) % 60) + $0.0.replacingOccurrences(of: "_", with: " ") + ($0.2 > 1 ? " ×\($0.2)" : "") }
            .joined(separator: " · ")
    }
}
