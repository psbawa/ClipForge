import Foundation

/// The shared "Pro Editor" layer: picks or applies a style profile, plans with it, self-reviews the plan like a
/// senior editor, and turns intensity into deterministic density of zooms / sound effects / accent transitions.
enum EditPlanner {
    static let critiqueModel = "claude-sonnet-5-5"
    static let pickModel = "claude-haiku-5-5"

    /// Planner prompt addition for a profile + intensity (0 subtle … 1 aggressive).
    static func guide(_ p: StyleProfile, intensity: Double) -> String {
        let shot = p.pacing.avgShotSeconds * (1.3 - 0.6 * intensity)
        return """

        EDITING STYLE (follow it closely)
        \(p.guide)
        Intensity \(Int(intensity * 100))%: aim for ~\(String(format: "%.1f", shot)) s average segments.

        Also per beat, optional:
        - "zoom": punch-in scale like 1.1 on emphasis/reaction beats (omit for none).
        - "sfx": list from ["whoosh", "hit", "riser"] — whoosh on accent transitions, hit on impacts, riser leading into the climax.
        Top-level, optional: "notes": one string with 3–5 short lines (separated by \\n) explaining your editing choices ("why I edited it this way").
        """
    }

    static let critiqueSystem = """
    You are a senior short-form video editor reviewing a junior's edit plan (JSON) before it renders. Check, against the style guide:
    hook strength in the first 1–3 s; pacing and dead air; a pattern interrupt every few seconds in short-form; clarity of the story
    (hook → build → payoff) and a strong ending or loop; caption readability (short, punchy, max 6 words); audio balance (sfx not overused);
    variety (no near-duplicate beats); every beat still inside the candidate windows it came from.

    Return ONLY a JSON object: {"notes": "3–5 short lines: what you changed and why", "plan": <the full revised plan, same schema>}.
    Keep everything that already works. Never invent footage: beats must keep start/end inside the original candidate windows.
    """

    /// Auto style: cheap Haiku pick from the library based on what the video is.
    static func autoPick(_ options: StoryOptions, words: [Word], profiles: [StyleProfile], client: LLMClient,
                         cost: CostTracker, settings: AppSettings) async throws -> StyleProfile {
        guard !profiles.isEmpty else { throw ClipForgeError("No style profiles are installed.") }
        let list = profiles.map { "\($0.id): \($0.name) — \($0.summary) [niches: \($0.niches.joined(separator: ", "))]" }.joined(separator: "\n")
        let user = """
        Content: \(options.gameName.isEmpty ? "unknown game/topic" : options.gameName). Edit type: \(options.style.rawValue), \(options.format.label), \(Int(options.targetSeconds)) s.
        Creator direction: \(options.prompt.isEmpty ? "—" : options.prompt)
        Speech sample: \(Array(words.prefix(120)).joinedText.isEmpty ? "(no speech)" : String(Array(words.prefix(120)).joinedText.prefix(600)))

        Styles:
        \(list)

        Answer with ONLY the id of the best-fitting style.
        """
        guard await cost.canSpend(budget: settings.dailyBudgetUSD) else { throw HighlightError.budgetReached }
        let r = try await client.complete(model: pickModel, system: "You pick the best editing style for a video. Reply with one id only.",
                                          user: user, maxTokens: 50, effort: "low")
        await cost.record(r.usage, price: settings.prices[pickModel])
        let answer = r.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let p = profiles.first(where: { answer.contains($0.id) }) else {
            throw ClipForgeError("Couldn't pick a style automatically (got “\(answer.prefix(40))”). Choose one in the style picker.")
        }
        return p
    }

    struct Critique: Decodable {
        var notes: String; var plan: Storyboard
        enum CodingKeys: String, CodingKey { case notes, plan }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            plan = try c.decode(Storyboard.self, forKey: .plan)
            notes = Storyboard.lines(c, .notes) ?? ""
        }
    }

    /// One review-and-revise pass. Returns the revised plan, or the original with a note if the review was unusable.
    static func critique(_ sb: Storyboard, profile: StyleProfile, options: StoryOptions, moments: [StoryMoment], duration: Double,
                         client: LLMClient, cost: CostTracker, settings: AppSettings) async throws -> Storyboard {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let plan = String(decoding: try enc.encode(sb), as: UTF8.self)
        let windows = moments.map { "Candidate \($0.index): \(String(format: "%.1f–%.1f", $0.start, $0.end)) s" }.joined(separator: "\n")
        let base = "Style guide:\n\(guide(profile, intensity: options.intensity))\n\nTarget: \(Int(options.targetSeconds)) s, \(options.style.rawValue), \(options.format.label)\n\(windows)\n\nPlan:\n\(plan)"
        var problem = ""
        for attempt in 0..<2 {
            guard await cost.canSpend(budget: settings.dailyBudgetUSD) else { throw HighlightError.budgetReached }
            let user = attempt == 0 ? base : base + "\n\nYour previous answer was rejected: \(problem). Return only the corrected JSON object."
            let r = try await client.complete(model: critiqueModel, system: critiqueSystem, user: user, maxTokens: 8000, effort: "medium")
            await cost.record(r.usage, price: settings.prices[critiqueModel])
            guard let a = r.text.firstIndex(of: "{"), let b = r.text.lastIndex(of: "}"),
                  let c = try? JSONDecoder().decode(Critique.self, from: Data(r.text[a...b].utf8)) else { problem = "not the required JSON object"; continue }
            if let err = StoryWriter.validate(c.plan, moments: moments, duration: duration, style: options.style) { problem = err; continue }
            var out = c.plan
            out.notes = [sb.notes, c.notes].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            return out
        }
        var out = sb
        out.notes = (sb.notes ?? "") + "\n(Senior-editor review skipped: \(problem).)"
        return out
    }

    /// Intensity → deterministic density of zooms, sfx and accent transitions (no model call; the slider re-renders instantly).
    static func applyIntensity(_ sb: Storyboard, profile: StyleProfile, intensity: Double) -> Storyboard {
        var out = sb
        let dur = sb.outputDuration
        let maxZooms = Int((profile.motion.punchInsPer10s * dur / 10 * (0.4 + intensity)).rounded())
        let sfxEvery = max(1, Int((1 / max(0.05, profile.sound.sfxDensity * (0.3 + intensity))).rounded()))
        let maxAccents = Int((Double(sb.beats.count) * profile.motion.accentRate * (0.4 + intensity)).rounded())
        var zooms = 0, accents = 0
        for i in out.beats.indices {
            if out.beats[i].zoom != nil {
                if zooms < maxZooms { zooms += 1; out.beats[i].zoom = min(out.beats[i].zoom!, profile.motion.punchInScale + 0.05 * intensity) }
                else { out.beats[i].zoom = nil }
            }
            if let t = out.beats[i].transition, t != "cut", i > 0 {
                if accents < maxAccents, profile.motion.accentTransitions.contains(t) || t == "fade" { accents += 1 } else { out.beats[i].transition = "cut" }
            }
            if !profile.motion.speedRamps { out.beats[i].speed = 1 }
            out.beats[i].sfx = out.beats[i].sfx?.filter { k in
                (k == "whoosh" && profile.sound.whooshOnAccents) || (k == "hit" && profile.sound.hitsOnImpacts) || (k == "riser" && profile.sound.riserBeforeClimax)
            }
            if i % sfxEvery != 0, out.beats[i].purpose != "climax" { out.beats[i].sfx = nil }
        }
        return out
    }

    /// Color look per profile (ffmpeg video filters, appended after framing).
    static func grade(_ color: String) -> String {
        switch color {
        case "punchy": ",eq=contrast=1.08:saturation=1.3"
        case "cinematic": ",eq=contrast=1.06:saturation=0.92:brightness=-0.015,colortemperature=temperature=5800"
        case "warm": ",colortemperature=temperature=5200,eq=saturation=1.1"
        case "cool": ",colortemperature=temperature=7600"
        case "muted": ",eq=saturation=0.78:contrast=0.96:brightness=0.02"
        default: ""
        }
    }

    /// Smooth punch-in that eases to `scale` over ~0.4 s and holds.
    /// With d=1 every input frame restarts `zoom`; only `pzoom` (previous frame's zoom) accumulates into a ramp.
    static func punchIn(_ scale: Double, size: (w: Int, h: Int)) -> String {
        let step = max(0.002, (scale - 1) / 12)
        return String(format: ",zoompan=z='min(pzoom+%.4f,%.3f)':d=1:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=%dx%d:fps=%d",
                      step, scale, size.w, size.h, StoryConfig.fps)
    }

    /// Sound-effect cues on the output timeline: whoosh into accent transitions, hit on impacts, riser ending at the climax.
    static func sfxCues(_ sb: Storyboard) -> [(kind: SFXLibrary.Kind, at: Double)] {
        var cues: [(SFXLibrary.Kind, Double)] = []
        for (b, o) in zip(sb.beats, StoryTimeline.starts(sb.beats)) {
            for k in b.sfx ?? [] {
                switch k {
                case "whoosh": cues.append((.whoosh, max(0, o - 0.2)))
                case "hit": cues.append((.hit, o))
                case "riser": cues.append((.riser, max(0, o - SFXLibrary.length(.riser))))
                default: break
                }
            }
        }
        return cues.sorted { $0.1 < $1.1 }
    }
}
