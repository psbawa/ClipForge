import Charts
import SwiftUI

struct ChannelStatsView: View {
    static let pageID = UUID(uuidString: "5701E5A0-0000-4000-8000-000000000003")!
    @Bindable var model: AppModel
    @State var filter = 0          // 0 all, 1 Shorts, 2 long
    @State var sort = 0            // 0 newest, 1 views, 2 % viewed, 3 subs
    @State var selected: VideoStats.ID?
    @State var curve: [RetentionPoint] = []

    var body: some View {
        Group {
            if !model.statsSignedIn && model.channelStats == nil {
                ContentUnavailableView {
                    Label("Channel Stats", systemImage: "chart.bar.xaxis")
                } description: {
                    Text("Read-only sign-in (youtube.readonly + yt-analytics.readonly). ClipForge can't change anything on your channel with it. Uses your Google OAuth client from Settings → Accounts; enable the “YouTube Analytics API” in that Google Cloud project.")
                } actions: {
                    Button("Sign In (read-only)") { Task { await model.signInStats() } }.buttonStyle(.themedPrimary)
                }
            } else if let s = model.channelStats {
                ScrollView { content(s).padding() }
            } else {
                ProgressView("Loading channel stats…").task { await model.refreshStats() }
            }
        }
        .toolbar {
            if model.statsBusy { ProgressView().controlSize(.small) }
            Button { Task { await model.refreshStats() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!model.statsSignedIn || model.statsBusy)
            Menu { Button("Sign out of Channel Stats") { Task { await model.signOutStats() } } } label: { Image(systemName: "person.crop.circle") }.disabled(!model.statsSignedIn)
        }
        .task { await model.loadStatsState() }
    }

    @ViewBuilder func content(_ s: ChannelSnapshot) -> some View {
        let last28 = s.days.suffix(28)
        let split = ChannelAnalytics.split(s.videos)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(s.channelTitle).themeFont(.title, weight: .bold, display: true)
                Spacer()
                Text("Updated \(s.takenAt.formatted(date: .abbreviated, time: .shortened))").themeFont(.caption).foregroundStyle(.themeMuted)
            }
            HStack(spacing: 10) {
                StatCard("Subscribers", s.subscribers.formatted(), "+\(last28.map(\.subscribers).reduce(0, +)) in 28 days", feature: .stats)
                StatCard("Views (28 days)", last28.map(\.views).reduce(0, +).formatted(), feature: .highlights)
                StatCard("Watch time (28 days)", "\(Int(last28.map(\.minutes).reduce(0, +) / 60).formatted()) h", feature: .vlog)
                StatCard("Videos", s.videoCount.formatted(), "\(split.shorts.count) Shorts · \(split.long.count) long", feature: .review)
            }
            Text(ChannelAnalytics.unavailableNote).themeFont(.caption).foregroundStyle(.themeMuted)

            if !s.days.isEmpty {
                Text("Daily views (\(s.days.count) days)").themeFont(.headline, display: true)
                Chart(s.days, id: \.day) { d in
                    BarMark(x: .value("Day", ChannelAnalytics.parseDay(d.day) ?? .now, unit: .day), y: .value("Views", d.views)).foregroundStyle(.themeChart(0))
                }.frame(height: 160)
            }

            HStack(alignment: .top, spacing: 16) {
                GroupBox("Shorts vs long videos") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shorts: \(split.shorts.count) · median \(split.shorts.medianViews.formatted()) views · \(String(format: "%.0f", split.shorts.avgPercent))% viewed")
                        Text("Long: \(split.long.count) · median \(split.long.medianViews.formatted()) views · \(String(format: "%.0f", split.long.avgPercent))% viewed")
                    }.themeFont(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("When your uploads did best") {
                    let slots = ChannelAnalytics.bestSlots(s.videos).prefix(4)
                    VStack(alignment: .leading, spacing: 4) {
                        if slots.isEmpty { Text("Need at least 2 uploads in the same weekday/time slot.").foregroundStyle(.themeMuted) }
                        ForEach(Array(slots), id: \.label) { x in Text("\(x.label) — median \(x.medianViews.formatted()) views (\(x.count) uploads)") }
                        Text("Based on when your past uploads were published, not live audience activity.").themeFont(.caption2).foregroundStyle(.themeMuted)
                    }.themeFont(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("What works on this channel").themeFont(.headline, display: true)
                        Spacer()
                        Button(s.patterns.isEmpty ? "Find patterns" : "Re-run") { Task { await model.findPatterns() } }.disabled(model.statsBusy)
                    }
                    if s.patterns.isEmpty { Text("Claude compares your best and worst videos. The patterns are also used when suggesting titles.").foregroundStyle(.themeMuted) }
                    ForEach(s.patterns, id: \.self) { Text("• " + $0).fixedSize(horizontal: false, vertical: true) }
                    if let at = s.patternsAt { Text("From \(at.formatted(date: .abbreviated, time: .omitted))").themeFont(.caption2).foregroundStyle(.themeMuted) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text("Videos").themeFont(.headline, display: true)
                Spacer()
                Picker("", selection: $filter) { Text("All").tag(0); Text("Shorts").tag(1); Text("Long").tag(2) }.pickerStyle(.segmented).frame(width: 220)
                Picker("Sort", selection: $sort) { Text("Newest").tag(0); Text("Views").tag(1); Text("% viewed").tag(2); Text("Subs gained").tag(3) }.frame(width: 160)
            }
            let vids = s.videos.filter { filter == 0 || (filter == 1) == $0.isShort }.sorted { a, b in
                switch sort { case 1: a.views > b.views; case 2: a.avgViewPercent > b.avgViewPercent; case 3: a.subscribersGained > b.subscribersGained; default: a.published > b.published }
            }
            Table(vids, selection: $selected) {
                TableColumn("Title") { v in Text(v.title).lineLimit(1) }.width(min: 220)
                TableColumn("Type") { v in Text(v.isShort ? "Short" : "Long") }.width(50)
                TableColumn("Published") { v in Text(v.published.formatted(date: .abbreviated, time: .omitted)) }.width(90)
                TableColumn("Views") { v in Text(v.views.formatted()).monospacedDigit() }.width(70)
                TableColumn("Avg view") { v in Text(String(format: "%.0fs · %.0f%%", v.avgViewSeconds, v.avgViewPercent)).monospacedDigit() }.width(90)
                TableColumn("Watch h") { v in Text(String(format: "%.1f", v.minutesWatched / 60)).monospacedDigit() }.width(60)
                TableColumn("Likes") { v in Text(v.likes.formatted()).monospacedDigit() }.width(50)
                TableColumn("Subs") { v in Text("+\(v.subscribersGained)").monospacedDigit() }.width(45)
            }
            .frame(height: 320)
            .onChange(of: selected) { _, id in
                curve = []
                if let id { Task { curve = await model.retention(id) } }
            }
            if let id = selected, let v = s.videos.first(where: { $0.id == id }) {
                GroupBox("Retention — \(v.title)") {
                    if curve.isEmpty { Text("No retention data yet (YouTube needs some views first).").foregroundStyle(.themeMuted) }
                    else {
                        Chart(curve, id: \.ratio) { p in
                            LineMark(x: .value("Position", p.ratio * 100), y: .value("Watching", p.watch * 100)).foregroundStyle(.themeChart(1))
                        }
                        .chartXAxisLabel("% of video").chartYAxisLabel("% of viewers still watching")
                        .frame(height: 180)
                    }
                }
            }
        }
    }
}
