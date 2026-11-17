import Foundation

/// Auto-publish limits. Pure: give it the history, get back nil (allowed) or the reason it's held for review.
public enum PublishPolicy {
    public struct Past: Sendable { public var date: Date; public var sourceID: UUID?; public var start: Double; public var end: Double }

    public static func check(score: Int, sourceID: UUID?, start: Double, end: Double, history: [Past], settings s: AppSettings, now: Date = .now) -> String? {
        if s.publishMode != .auto { return "Review mode" }
        if s.autoPublishKilled { return "Auto-publish kill switch is on" }
        if score < s.minAutoScore { return "Score \(score) is below the auto-publish minimum \(s.minAutoScore)" }
        if history.filter({ now.timeIntervalSince($0.date) < 3600 }).count >= s.maxPerHour { return "Hourly limit (\(s.maxPerHour)) reached" }
        if history.filter({ now.timeIntervalSince($0.date) < 86400 }).count >= s.maxPerDay { return "Daily limit (\(s.maxPerDay)) reached" }
        if let last = history.map(\.date).max(), now.timeIntervalSince(last) < s.minGapMinutes * 60 {
            return "Less than \(Int(s.minGapMinutes)) min since the last upload"
        }
        if history.contains(where: { $0.sourceID == sourceID && min($0.end, end) > max($0.start, start) }) {
            return "Overlaps a clip that was already published"
        }
        return nil
    }
}
