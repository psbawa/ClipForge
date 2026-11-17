import SwiftData
import SwiftUI

public struct RootView: View {
    @Bindable var model: AppModel
    var story: StoryModel?
    @Environment(\.modelContext) var context
    @Query(sort: \Source.createdAt, order: .reverse) var sources: [Source]
    @Query(filter: #Predicate<ClipRecord> { $0.statusRaw == "ready" }) var needsReview: [ClipRecord]
    @State var selection: UUID?
    @State var tab = Tab.dashboard
    @State var showAdd = false
    @State var showUpload = false
    @AppStorage("rights.firstRunAccepted") var firstRunAccepted = false

    enum Tab: String, CaseIterable { case dashboard = "Dashboard", clips = "Clips", log = "Publish Log" }

    public init(model: AppModel, story: StoryModel? = nil) { self.model = model; self.story = story }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    SidebarRow("Review Queue", "checklist", .review).badge(needsReview.count).tag(ReviewQueueView.pageID)
                    SidebarRow("All Clips", "play.rectangle.on.rectangle", .highlights).tag(AllClipsView.pageID)
                    if story != nil { SidebarRow("Story & Remix", "wand.and.stars", .story).tag(StoryModel.pageID) }
                    SidebarRow("Travel Vlog", "map", .vlog).tag(VlogView.pageID)
                    SidebarRow("Channel Stats", "chart.bar.xaxis", .stats).tag(ChannelStatsView.pageID)
                }
                Section("Sources") {
                    ForEach(sources) { s in
                        HStack {
                            Image(systemName: s.isLive ? "dot.radiowaves.left.and.right" : "film")
                                .foregroundStyle(s.id == model.runningSourceID ? .themeDanger : .themeMuted)
                            VStack(alignment: .leading) {
                                Text(s.title).lineLimit(1)
                                Text(s.channelName).themeFont(.caption).foregroundStyle(.themeMuted)
                            }
                        }
                        .tag(s.id)
                        .contextMenu { Button("Delete", role: .destructive) { delete(s) }.disabled(s.id == model.runningSourceID) }
                    }
                }
            }
            .background(.themeSurface)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                Button { showUpload = true } label: { Label("Upload Video from Mac", systemImage: "square.and.arrow.up") }
                Button { showAdd = true } label: { Label("Add Source", systemImage: "plus") }
            }
            .sheet(isPresented: $showUpload) { UploadFileSheet(model: model).themedSheet() }
        } detail: {
            VStack(spacing: 0) {
                BannerStack(model: model)
                if selection == ReviewQueueView.pageID {
                    ReviewQueueView(model: model)
                } else if selection == AllClipsView.pageID {
                    AllClipsView(model: model)
                } else if selection == ChannelStatsView.pageID {
                    ChannelStatsView(model: model)
                } else if selection == VlogView.pageID {
                    VlogView(model: model.vlog)
                } else if selection == StoryModel.pageID, let story {
                    StoryShortsView(model: story)
                } else if let s = sources.first(where: { $0.id == selection }) {
                    Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420).padding(10)
                    switch tab {
                    case .dashboard: DashboardView(model: model, source: s)
                    case .clips: ClipsGalleryView(model: model, source: s)
                    case .log: PublishLogView()
                    }
                } else {
                    ContentUnavailableView("No source selected", systemImage: "film.stack",
                                           description: Text("Add a YouTube live stream or video from a channel you own or have permission to clip."))
                }
            }
        }
        .sheet(isPresented: $showAdd) { AddSourceSheet(model: model) { selection = $0.id }.themedSheet() }
        .sheet(isPresented: .constant(!firstRunAccepted)) { FirstRunSheet { firstRunAccepted = true }.themedSheet() }
        .onAppear { if model.binaries == nil { model.notify(Binaries.setupHint, .warning) } }
        .task {
            model.resumeCompanion()
            await model.loadYouTubeChannel()
            _ = await model.refreshTrends()   // weekly, only when enabled and YouTube is connected
        }
    }

    func delete(_ s: Source) {
        if selection == s.id { selection = nil }
        try? FileManager.default.removeItem(at: s.folder)
        context.delete(s)
        try? context.save()
    }
}

struct BannerStack: View {
    @Bindable var model: AppModel
    var body: some View {
        ForEach(model.banners) { b in
            HStack(alignment: .top) {
                Image(systemName: b.kind == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                Text(b.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button { model.banners.removeAll { $0.id == b.id } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(10)
            .background(b.kind == .error ? ThemeColor.themeDanger.opacity(0.15) : b.kind == .warning ? ThemeColor.themeWarning.opacity(0.15) : ThemeColor.themeAccent.opacity(0.15))
        }
    }
}

struct FirstRunSheet: View {
    var accept: () -> Void
    @State var agreed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to ClipForge").themeFont(.title2, weight: .bold, display: true)
            Text("ClipForge records YouTube streams and videos, cuts highlights and publishes them as Shorts to **your own** channel. Only use it with content you own, or content whose rights holder has given you permission to clip and republish.")
            Toggle(RightsGuard.ownershipStatement, isOn: $agreed)
            Text("You'll confirm this again for every source. ClipForge only uses yt-dlp and the official YouTube Data API and never bypasses platform protections.")
                .themeFont(.caption).foregroundStyle(.themeMuted)
            HStack { Spacer(); Button("Continue", action: accept).keyboardShortcut(.defaultAction).disabled(!agreed) }
        }
        .padding(24).frame(width: 520)
        .interactiveDismissDisabled()
    }
}

struct AddSourceSheet: View {
    @Bindable var model: AppModel
    var added: (Source) -> Void
    @Environment(\.dismiss) var dismiss
    @State var url = ""
    @State var busy = false
    @State var error: String?
    @State var source: Source?
    @State var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Source").themeFont(.title3, weight: .bold, display: true)
            if let s = source {
                LabeledContent("Title", value: s.title)
                LabeledContent("Channel", value: "\(s.channelName) (\(s.channelID))")
                LabeledContent("Type", value: s.isLive ? "Live stream" : "Video")
                Toggle(RightsGuard.ownershipStatement, isOn: $confirmed)
                HStack {
                    Spacer()
                    Button("Done") {
                        if confirmed { s.ownershipConfirmedAt = .now; model.save() }
                        added(s); dismiss()
                    }.keyboardShortcut(.defaultAction)
                }
            } else {
                TextField("https://www.youtube.com/watch?v=…", text: $url).textFieldStyle(.roundedBorder).onSubmit(check)
                if let error { Text(error).foregroundStyle(.themeDanger).themeFont(.callout) }
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Check", action: check).keyboardShortcut(.defaultAction).disabled(url.isEmpty || busy)
                }
            }
        }
        .padding(20).frame(width: 520)
    }

    func check() {
        busy = true; error = nil
        Task {
            do { source = try await model.addSource(url: url) } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct DashboardView: View {
    @Bindable var model: AppModel
    @Bindable var source: Source
    var running: Bool { model.runningSourceID == source.id }
    /// Running now, or the last source that ran (its outcome stays on screen).
    var current: Bool { running || model.lastSourceID == source.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if source.ownershipConfirmedAt == nil {
                    GroupBox {
                        HStack {
                            Text(RightsGuard.ownershipStatement)
                            Spacer()
                            Button("Confirm") { source.ownershipConfirmedAt = .now; model.save() }
                        }
                    }
                }
                if let ch = model.youtubeChannel, source.channelID != ch.id { PermissionBox(model: model, source: source, channel: ch) }
                stages
                if current, !model.status.isEmpty {
                    HStack {
                        Text(model.status).foregroundStyle(.themeMuted)
                        if let p = model.progress { ProgressView(value: p).frame(maxWidth: 240) }
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    GroupBox("Transcript (live tail)") {
                        ScrollView { Text(running ? model.transcriptTail : "—").frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            .frame(height: 140)
                    }
                    GroupBox("API cost") {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("This session", value: model.sessionCost.formatted(.currency(code: "USD").precision(.fractionLength(4))))
                            LabeledContent("Today", value: model.todayCost.formatted(.currency(code: "USD").precision(.fractionLength(4))))
                            LabeledContent("Daily cap", value: model.settings.dailyBudgetUSD > 0 ? model.settings.dailyBudgetUSD.formatted(.currency(code: "USD")) : "None")
                        }.frame(width: 220)
                    }
                }
                GroupBox("Candidate moments") {
                    if !current || model.candidates.isEmpty {
                        Text("Candidates appear here as the stream is scored.").foregroundStyle(.themeMuted).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Table(model.candidates.sorted { $0.effectiveScore > $1.effectiveScore }) {
                            TableColumn("Time") { Text("\(AppModel.clock($0.start))–\(AppModel.clock($0.end))").monospacedDigit() }.width(110)
                            TableColumn("Fast") { Text("\($0.score)") }.width(40)
                            TableColumn("Final") { Text($0.finalScore.map(String.init) ?? "—") }.width(40)
                            TableColumn("Title", value: \.title)
                            TableColumn("Why", value: \.reason)
                        }.frame(height: 200)
                    }
                }
                GroupBox("Recent publishes") { RecentPublishes(sourceTitle: source.title) }
                GroupBox("Queue") {
                    HStack(spacing: 18) {
                        ForEach(ClipStatus.allCases, id: \.self) { st in
                            let n = source.clips.filter { $0.status == st }.count
                            if n > 0 { VStack { Text("\(n)").themeFont(.title3, weight: .bold, display: true); Text(st.label).themeFont(.caption) } }
                        }
                        if source.clips.isEmpty { Text("No clips yet").foregroundStyle(.themeMuted) }
                        Spacer()
                    }
                }
            }
            .padding()
        }
    }

    var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text(source.title).themeFont(.title2, weight: .bold, display: true).lineLimit(2)
                Text("\(source.channelName) · \(source.isLive ? "Live" : "Video")").foregroundStyle(.themeMuted)
                Link(source.url, destination: URL(string: source.url) ?? URL(string: "https://youtube.com")!).themeFont(.caption)
            }
            Spacer()
            if model.settings.publishMode == .auto {
                Toggle("Auto-publish", isOn: Binding(get: { !model.settings.autoPublishKilled }, set: { model.settings.autoPublishKilled = !$0 }))
                    .toggleStyle(.switch)
                    .help("Global kill switch for auto-publishing")
            }
            if running {
                Button(model.isPaused ? "Resume" : "Pause") { model.isPaused.toggle() }
                Button("Stop", role: .destructive) { model.stop() }
            } else {
                Button(source.wasRunning ? "Resume" : "Start") { model.start(source) }
                    .buttonStyle(.themedPrimary)
                    .disabled(model.runningSourceID != nil || source.ownershipConfirmedAt == nil)
            }
        }
    }

    var stages: some View {
        HStack(spacing: 6) {
            ForEach(AppModel.Stage.allCases, id: \.self) { st in
                Text(st.rawValue.capitalized)
                    .themeFont(.caption, weight: .bold)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(running && model.stage == st ? ThemeColor.themeAccent : ThemeColor.themeRaised))
                    .foregroundStyle(running && model.stage == st ? .themeOnAccent : .themeMuted)
            }
            if running && model.isPaused { Text("PAUSED").themeFont(.caption, weight: .bold).foregroundStyle(.themeWarning) }
        }
    }
}

struct PublishLogView: View {
    @Query(sort: \PublishLogEntry.date, order: .reverse) var entries: [PublishLogEntry]
    var body: some View {
        Table(entries) {
            TableColumn("Date") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }.width(140)
            TableColumn("Title", value: \.title)
            TableColumn("Source", value: \.sourceTitle)
            TableColumn("Result", value: \.result)
            TableColumn("Privacy") { Text("\($0.requestedPrivacy) → \($0.returnedPrivacy ?? "?")") }.width(130)
            TableColumn("Video") { e in
                if let id = e.videoID, let u = URL(string: "https://youtube.com/shorts/\(id)") { Link(id, destination: u) } else { Text("—") }
            }.width(110)
            TableColumn("Rights basis", value: \.rightsBasis)
        }
    }
}

struct PermissionBox: View {
    @Bindable var model: AppModel
    @Bindable var source: Source
    var channel: Channel
    @State var note = ""
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("This source belongs to \(source.channelName.isEmpty ? source.channelID : source.channelName), not your channel “\(channel.title)”.",
                      systemImage: "person.2.badge.key")
                if let d = source.permissionConfirmedAt {
                    Text("Permission recorded \(d.formatted(date: .abbreviated, time: .shortened))\(source.permissionNote.isEmpty ? "" : ": " + source.permissionNote)")
                        .foregroundStyle(.themeMuted)
                    Button("Revoke") { source.permissionConfirmedAt = nil; model.save() }
                } else {
                    Text("Publishing (manual and auto) is blocked until you record the rights holder's permission.").foregroundStyle(.themeMuted)
                    TextField("How permission was given (e.g. email from creator on 3 Nov)", text: $note)
                    Button("I have the rights holder's permission to clip and publish this content") {
                        source.permissionConfirmedAt = .now
                        source.permissionNote = note
                        model.save()
                    }.disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RecentPublishes: View {
    @Query(sort: \PublishLogEntry.date, order: .reverse) var entries: [PublishLogEntry]
    var sourceTitle: String
    var body: some View {
        let mine = entries.filter { $0.sourceTitle == sourceTitle }.prefix(5)
        VStack(alignment: .leading, spacing: 4) {
            if mine.isEmpty { Text("Nothing published yet").foregroundStyle(.themeMuted) }
            ForEach(Array(mine)) { e in
                HStack {
                    Text(e.date.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(.themeMuted)
                    Text(e.title).lineLimit(1)
                    Spacer()
                    Text(e.result).foregroundStyle(e.result == "Published" ? .themeSuccess : .themeDanger).lineLimit(1)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
