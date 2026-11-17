import Foundation

/// Royalty-free sound effects: the user's own files in ~/Music/ClipForge/SFX/<type>/, else simple effects
/// ClipForge synthesizes itself with ffmpeg (no third-party audio is ever downloaded).
public enum SFXLibrary {
    public enum Kind: String, CaseIterable, Sendable, Codable { case whoosh, hit, riser, pop }

    static var root: URL { StoryConfig.musicRoot.appendingPathComponent("SFX") }

    /// A user file for the kind if there is one (random among them), else the generated fallback.
    static func file(_ kind: Kind, ffmpeg: URL) async throws -> URL {
        let dir = root.appendingPathComponent(kind.rawValue)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let own = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter({ MusicLibrary.audioTypes.contains($0.pathExtension.lowercased()) }).randomElement() { return own }
        let gen = root.appendingPathComponent("_generated/\(kind.rawValue).m4a")
        if !FileManager.default.fileExists(atPath: gen.path) {
            try FileManager.default.createDirectory(at: gen.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (src, dur, af) = recipe(kind)
            try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "\(src):d=\(dur)",
                                         "-af", af, "-ac", "2", "-c:a", "aac", "-b:a", "160k", gen.path])
        }
        return gen
    }

    /// Length of each generated effect, and where its "impact" lands (a riser should end on the hit).
    static func length(_ kind: Kind) -> Double { kind == .riser ? 2.0 : kind == .whoosh ? 0.45 : kind == .hit ? 0.8 : 0.12 }

    static func recipe(_ k: Kind) -> (String, Double, String) {
        switch k {
        case .whoosh: ("anoisesrc=color=pink:amplitude=0.8", 0.45,
                       "highpass=f=300,lowpass=f=6000,afade=t=in:d=0.2,afade=t=out:st=0.2:d=0.25,volume=0.9")
        case .hit: ("aevalsrc='0.9*sin(2*PI*(45+120*exp(-t*18))*t)*exp(-t*6)+0.25*(2*random(0)-1)*exp(-t*30)':s=44100", 0.8,
                    "lowpass=f=3000,volume=1.0")
        case .riser: ("aevalsrc='0.35*sin(2*PI*(200+600*t*t)*t)*(t/2)+0.15*(2*random(0)-1)*(t/2)':s=44100", 2.0,
                      "highpass=f=150,afade=t=out:st=1.92:d=0.08")
        case .pop: ("aevalsrc='0.8*sin(2*PI*900*t)*exp(-t*60)':s=44100", 0.12, "volume=0.8")
        }
    }
}
