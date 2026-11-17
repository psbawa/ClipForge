import Foundation

/// Hookable titles that are never misleading: Sonnet writes options, then a separate check rejects any claim
/// the clip's evidence (transcript, detected events, frames) doesn't show.
public enum TitleWriter {
    static let model = "claude-sonnet-5-5"
    static let checkModel = "claude-haiku-5-5"
    static let hooks = ["curiosity", "number", "challenge", "emotion", "pov"]

    static let system = """
    You write YouTube Shorts titles that make people stop scrolling — without lying. You get a clip's evidence: what was
    detected in it, what is said, frames, and (if available) patterns that work on this creator's channel.
    Write 5 options, each ≤ 60 characters, each with a different hook type: curiosity, number, challenge, emotion, pov.
    Rules: every claim must be visible or audible in the clip (no invented kills, wins, reactions, records, or people);
    numbers must come from the evidence; no "you won't believe", no ALL CAPS sentences, max 1 emoji, no hashtags.
    Use the channel patterns when they apply. Mark the single best one as recommended.
    Output ONLY: [{"title": "...", "hook": "number", "recommended": true}, ...]
    """
    static let checkSystem = """
    You are a strict fact checker for video titles. For each title, decide whether everything it claims or implies
    (events, counts, outcomes, emotions, who is involved) is supported by the clip evidence and frames. Curiosity framing is
    fine; claims are not. If a title overstates (e.g. "1v5" when the evidence shows 2 kills), it is NOT supported.
    Output ONLY: [{"index": 1, "supported": true, "problem": ""}, ...]  (problem: one short sentence when unsupported)
    """

    struct Option: Decodable { var title: String; var hook: String; var recommended: Bool? }
    struct Verdict: Decodable { var index: Int; var supported: Bool; var problem: String? }

    static func evidence(title: String, reason: String, said: String, patterns: [String]) -> String {
        """
        Current title: \(title)
        Why the clip was picked / detected events: \(reason.isEmpty ? "—" : reason)
        Transcript: \(said.isEmpty ? "(no speech)" : String(said.prefix(1500)))
        Channel patterns: \(patterns.isEmpty ? "(none yet)" : patterns.map { "- " + $0 }.joined(separator: "\n"))
        """
    }

    static func json<T: Decodable>(_ text: String) -> [T]? {
        guard let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]") else { return nil }
        return try? JSONDecoder().decode([T].self, from: Data(text[a...b].utf8))
    }

    public static func options(title: String, reason: String, said: String, frames: [Data], patterns: [String],
                               client: LLMClient, cost: CostTracker, settings: AppSettings) async throws -> [TitleOption] {
        let ev = evidence(title: title, reason: reason, said: said, patterns: patterns)
        let images = frames.map { LLMContent.jpeg($0) }
        guard await cost.canSpend(budget: settings.dailyBudgetUSD) else { throw HighlightError.budgetReached }
        var opts: [Option]?
        for _ in 0..<2 where opts == nil {
            let r = try await client.complete(model: model, system: system, content: [.text(ev)] + images + [.text("Return the JSON array now.")], maxTokens: 1200, effort: "medium")
            await cost.record(r.usage, price: settings.prices[model])
            opts = json(r.text).flatMap { (o: [Option]) in o.isEmpty ? nil : o }
        }
        guard let opts else { throw ClipForgeError("Couldn't get title options from Claude. Try again.") }
        var out = opts.prefix(5).map { o in
            TitleOption(title: String(o.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)),
                        hook: hooks.contains(o.hook.lowercased()) ? o.hook.lowercased() : "curiosity", recommended: o.recommended ?? false)
        }
        // Enforced, not just requested: a separate check against the same evidence.
        let list = out.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")
        let r = try await client.complete(model: checkModel, system: checkSystem, content: [.text(ev + "\n\nTitles:\n" + list)] + images, maxTokens: 800, effort: "low")
        await cost.record(r.usage, price: settings.prices[checkModel])
        guard let verdicts: [Verdict] = json(r.text) else { throw ClipForgeError("The title fact check didn't answer clearly, so no titles were approved. Try again.") }
        for v in verdicts where out.indices.contains(v.index - 1) {
            out[v.index - 1].supported = v.supported
            out[v.index - 1].problem = v.supported ? nil : (v.problem?.isEmpty == false ? v.problem : "Not supported by the clip.")
        }
        // Unchecked options count as rejected; recommendation only among supported ones.
        let checked = Set(verdicts.map { $0.index - 1 })
        for i in out.indices where !checked.contains(i) { out[i].supported = false; out[i].problem = "Not checked." }
        if !out.contains(where: { $0.recommended && $0.supported }), let i = out.firstIndex(where: \.supported) {
            for k in out.indices { out[k].recommended = k == i }
        }
        for k in out.indices where !out[k].supported { out[k].recommended = false }
        return out
    }
}
