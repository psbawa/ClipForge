import Foundation

/// A versioned, data-driven editing recipe ("trend profile"). Seeds ship as JSON resources; refreshed,
/// reference-derived or user-edited versions are written next to them with a date and never overwrite history.
public struct StyleProfile: Codable, Sendable, Hashable, Identifiable {
    public struct Pacing: Codable, Sendable, Hashable {
        public var avgShotSeconds: Double        // target average segment/shot length
        public var patternInterruptSeconds: Double // short-form: something changes at least this often
        public var cutFillers: Bool               // remove "um"/long pauses in talking parts
    }
    public struct Captions: Codable, Sendable, Hashable {
        public var style: CaptionStyle            // pop / clean / boxed renderer
        public var animation: String              // "none" | "pop" (active word pops in)
        public var uppercase: Bool
        public var emoji: Bool
        public var wordsPerCard: Int
    }
    public struct Motion: Codable, Sendable, Hashable {
        public var punchInsPer10s: Double         // subtle zooms on emphasis/reactions
        public var punchInScale: Double           // e.g. 1.12
        public var speedRamps: Bool               // slow-mo on peaks
        public var accentTransitions: [String]    // from cut/fade/flash/zoom/whip; "cut" is the default
        public var accentRate: Double             // share of transitions that use an accent (0–1)
    }
    public struct Sound: Codable, Sendable, Hashable {
        public var whooshOnAccents: Bool
        public var hitsOnImpacts: Bool
        public var riserBeforeClimax: Bool
        public var sfxDensity: Double             // 0–1
        public var musicMood: StoryTone
        public var musicEnergy: String            // low / medium / high
    }

    public var id: String
    public var version: String                    // yyyy-MM-dd (or with time) of this revision
    public var name: String
    public var summary: String                    // shown in the style picker
    public var platforms: [String]
    public var niches: [String]
    public var hook: String
    public var structure: String
    public var idealSeconds: Double
    public var pacing: Pacing
    public var captions: Captions
    public var motion: Motion
    public var sound: Sound
    public var color: String                      // neutral / punchy / cinematic / warm / cool / muted
    public var origin: String                     // seed / trend-refresh / reference / user
    public var notes: String = ""                 // evidence for refreshed/reference profiles

    /// Text block for the planner prompt.
    var guide: String {
        """
        Style: \(name) — \(summary)
        Hook: \(hook)
        Structure: \(structure)
        Pacing: average shot ≈ \(String(format: "%.1f", pacing.avgShotSeconds)) s; something changes at least every \(String(format: "%.1f", pacing.patternInterruptSeconds)) s (cut, punch-in, text, sound hit).
        Transitions: mostly hard cuts; accents (\(motion.accentTransitions.joined(separator: ", "))) on about \(Int(motion.accentRate * 100))% of cuts.
        Punch-in zooms: about \(String(format: "%.1f", motion.punchInsPer10s)) per 10 s on emphasis/reactions. Slow-mo on peaks: \(motion.speedRamps ? "yes, 1–2 max" : "no").
        Captions: \(captions.uppercase ? "UPPERCASE" : "sentence case"), ~\(captions.wordsPerCard) words per card\(captions.emoji ? ", an emoji is OK when it fits" : ", no emoji").
        Ideal length: ~\(Int(idealSeconds)) s.
        """
    }
}

/// Loads seed profiles from the package and user/refreshed versions from Application Support. Latest version wins;
/// every version stays on disk as history.
public enum StyleLibrary {
    @TaskLocal static var rootOverride: URL?   // tests only; task-local so parallel tests can't see each other's folders
    static var root: URL {
        let u = rootOverride ?? Paths.support.appendingPathComponent("styles")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func seeds() -> [StyleProfile] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return urls.compactMap { try? JSONDecoder().decode(StyleProfile.self, from: Data(contentsOf: $0)) }
    }

    /// All saved versions of every profile (seed versions included), oldest first.
    public static func history(_ id: String? = nil) -> [StyleProfile] {
        var all = seeds()
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where id == nil || dir.lastPathComponent == id {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
                if let p = try? JSONDecoder().decode(StyleProfile.self, from: Data(contentsOf: f)) { all.append(p) }
            }
        }
        return all.filter { id == nil || $0.id == id }.sorted { ($0.id, $0.version) < ($1.id, $1.version) }
    }

    /// Latest version of each profile.
    public static func all() -> [StyleProfile] {
        Dictionary(grouping: history(), by: \.id).compactMap { $0.value.max { $0.version < $1.version } }.sorted { $0.name < $1.name }
    }

    public static func profile(_ id: String) -> StyleProfile? { all().first { $0.id == id } }

    /// Writes a new dated version; never overwrites an existing file.
    @discardableResult
    public static func save(_ p: StyleProfile) throws -> URL {
        let dir = root.appendingPathComponent(p.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent("\(p.version).json"), n = 1
        while FileManager.default.fileExists(atPath: url.path) { n += 1; url = dir.appendingPathComponent("\(p.version)-\(n).json") }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(p).write(to: url)
        return url
    }

    /// Lay a model-written (possibly partial) profile JSON over a complete base profile: only fields the model
    /// actually sent change; unknown enum values (caption style, music mood) are ignored. nil if nothing usable.
    static func merge(_ base: StyleProfile, patch: Any) -> StyleProfile? {
        guard var dict = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(base))) as? [String: Any],
              var p = patch as? [String: Any] else { return nil }
        if var c = p["captions"] as? [String: Any], let st = c["style"] as? String, CaptionStyle(rawValue: st) == nil { c["style"] = nil; p["captions"] = c }
        if var s = p["sound"] as? [String: Any], let m = s["musicMood"] as? String, StoryTone(rawValue: m) == nil { s["musicMood"] = nil; p["sound"] = s }
        func deep(_ a: inout [String: Any], _ b: [String: Any]) {
            for (k, v) in b {
                if let vb = v as? [String: Any], var va = a[k] as? [String: Any] { deep(&va, vb); a[k] = va }
                else if !(v is NSNull), a[k] != nil { a[k] = v }   // only known keys
            }
        }
        deep(&dict, p)
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(StyleProfile.self, from: data)
    }

    static var today: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: .now)
    }
}
