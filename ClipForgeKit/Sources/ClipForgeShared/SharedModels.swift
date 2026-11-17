import Foundation

// Types shared by the Mac app and the iPhone companion (stats, title ideas). Pure data + math; no networking here.

public struct VideoStats: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var published: Date
    public var seconds: Double
    public var views = 0
    public var minutesWatched = 0.0
    public var avgViewSeconds = 0.0
    public var avgViewPercent = 0.0
    public var likes = 0
    public var comments = 0
    public var subscribersGained = 0
    public var isShort: Bool { seconds <= 180 }
    public init(id: String, title: String, published: Date, seconds: Double) { self.id = id; self.title = title; self.published = published; self.seconds = seconds }
}

public struct DayStats: Codable, Sendable, Hashable {
    public var day: String; public var views: Int; public var minutes: Double; public var subscribers: Int
    public init(day: String, views: Int, minutes: Double, subscribers: Int) { self.day = day; self.views = views; self.minutes = minutes; self.subscribers = subscribers }
}

/// One pull of the channel's numbers, saved per day so the dashboard opens offline and trends survive.
public struct ChannelSnapshot: Codable, Sendable {
    public var takenAt = Date()
    public var channelTitle = ""
    public var subscribers = 0
    public var totalViews = 0
    public var videoCount = 0
    public var videos: [VideoStats] = []
    public var days: [DayStats] = []
    public var patterns: [String] = []          // "what works on my channel", written by Claude
    public var patternsAt: Date?
    public init() {}
}

public struct RetentionPoint: Codable, Sendable, Hashable {
    public var ratio: Double; public var watch: Double; public var relative: Double
    public init(ratio: Double, watch: Double, relative: Double) { self.ratio = ratio; self.watch = watch; self.relative = relative }
}

public struct TitleOption: Codable, Sendable, Hashable, Identifiable {
    public var id: String { title }
    public var title: String
    public var hook: String              // curiosity / number / challenge / emotion / POV
    public var recommended = false
    public var supported = true          // fact check verdict
    public var problem: String?          // why it was rejected
    public init(title: String, hook: String, recommended: Bool = false, supported: Bool = true, problem: String? = nil) {
        self.title = title; self.hook = hook; self.recommended = recommended; self.supported = supported; self.problem = problem
    }
}

/// Channel numbers: the Mac fetches them (read-only APIs); both apps display them.
public enum ChannelAnalytics {
    /// Impressions and click-through rate are only in YouTube Studio; the public APIs don't expose them.
    public static let unavailableNote = "Impressions and click-through rate aren't available through YouTube's API (Studio only)."
    public static func parseDay(_ s: String) -> Date? { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .init(identifier: "UTC"); return f.date(from: s) }
    public static func day(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .init(identifier: "UTC"); return f.string(from: d) }

    // MARK: Derived (pure, unit-tested)

    public struct Split: Sendable { public var count: Int; public var medianViews: Int; public var avgPercent: Double }
    public static func split(_ v: [VideoStats]) -> (shorts: Split, long: Split) {
        func f(_ x: [VideoStats]) -> Split {
            let views = x.map(\.views).sorted()
            return Split(count: x.count, medianViews: views.isEmpty ? 0 : views[views.count / 2],
                         avgPercent: x.isEmpty ? 0 : x.map(\.avgViewPercent).reduce(0, +) / Double(x.count))
        }
        return (f(v.filter(\.isShort)), f(v.filter { !$0.isShort }))
    }

    /// When your past uploads did best: median views by publish weekday and 4-hour block (your timezone). Needs ≥ 2 videos per slot.
    public static func bestSlots(_ v: [VideoStats], calendar: Calendar = .current) -> [(label: String, medianViews: Int, count: Int)] {
        var groups: [String: [Int]] = [:]
        for x in v where x.published > .distantPast {
            let wd = calendar.shortWeekdaySymbols[calendar.component(.weekday, from: x.published) - 1]
            let h = calendar.component(.hour, from: x.published) / 4 * 4
            groups["\(wd) \(String(format: "%02d", h)):00–\(String(format: "%02d", h + 4)):00", default: []].append(x.views)
        }
        return groups.filter { $0.value.count >= 2 }.map { k, vs in let s = vs.sorted(); return (k, s[s.count / 2], s.count) }
            .sorted { $0.medianViews > $1.medianViews }
    }

}
