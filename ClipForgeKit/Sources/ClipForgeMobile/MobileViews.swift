#if os(iOS)
import AVKit
import Charts
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

public struct MobileRootView: View {
    @Bindable var model: MobileModel
    @State var tab = 0
    public init(model: MobileModel) { self.model = model }

    public var body: some View {
        Group {
            if !model.isPaired { PairView(model: model) }
            else {
                TabView(selection: $tab) {
                    NavigationStack { ClipList(model: model, reviewOnly: true) }
                        .tabItem { Label("Review", systemImage: "checklist") }.badge(model.reviewQueue.count).tag(0)
                    NavigationStack { ClipList(model: model, reviewOnly: false) }
                        .tabItem { Label("Clips", systemImage: "play.rectangle.on.rectangle") }.tag(1)
                    NavigationStack { MobileStatsView(model: model) }
                        .tabItem { Label("Stats", systemImage: "chart.bar.xaxis") }.tag(2)
                    NavigationStack { MobileUploadView(model: model) }
                        .tabItem { Label("Upload", systemImage: "square.and.arrow.up") }.tag(3)
                    NavigationStack { MobileSettingsView(model: model) }
                        .tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
                }
            }
        }
        .overlay(alignment: .top) {
            if let m = model.message {
                Text(m).themeFont(.callout, weight: .semibold).foregroundStyle(.themeOnAccent)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Capsule().fill(.themeAccent)).padding(.top, 6)
                    .onTapGesture { model.message = nil }
                    .task(id: m) { try? await Task.sleep(for: .seconds(3)); if model.message == m { model.message = nil } }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.message)
    }
}

// MARK: Pairing

struct PairView: View {
    @Bindable var model: MobileModel
    @State var chosen: DiscoveredMac?
    @State var code = ""
    @State var manual = ""
    @State var showManual = false
    @State var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("On your Mac open ClipForge → Settings → iPhone, turn it on and press “Pair iPhone…”. Keep both on the same Wi-Fi.")
                        .themeFont(.callout).foregroundStyle(.themeMuted)
                }
                Section("Macs on this network") {
                    if model.discovered.isEmpty {
                        HStack { ProgressView(); Text("Looking for ClipForge…").foregroundStyle(.themeMuted) }
                    }
                    ForEach(model.discovered) { m in
                        Button { chosen = m } label: {
                            HStack { Image(systemName: "desktopcomputer"); Text(m.name); Spacer(); if chosen == m { Image(systemName: "checkmark").foregroundStyle(.themeAccent) } }
                        }.buttonStyle(.plain)
                    }
                    Button("Enter the Mac's address instead") { showManual.toggle() }.themeFont(.caption).buttonStyle(.plain).foregroundStyle(.themeAccent)
                    if showManual { TextField("192.168.1.20:52000", text: $manual).keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never) }
                }
                if chosen != nil || (showManual && !manual.isEmpty) {
                    Section("Code shown on the Mac") {
                        TextField("123 456", text: $code).keyboardType(.numberPad).themeFont(.title, weight: .bold, mono: true)
                        Button(working ? "Pairing…" : "Pair") {
                            working = true
                            Task {
                                if showManual && !manual.isEmpty { _ = await model.pair(address: manual, code: code) }
                                else if let chosen { _ = await model.pair(chosen, code: code) }
                                working = false
                            }
                        }
                        .buttonStyle(.themedPrimary)
                        .disabled(code.filter(\.isNumber).count != 6 || working)
                    }
                }
            }
            .navigationTitle("Connect to your Mac")
        }
    }
}

// MARK: Clips

struct ClipList: View {
    @Bindable var model: MobileModel
    let reviewOnly: Bool
    var items: [CompanionClip] { reviewOnly ? model.reviewQueue : model.clips }

    var body: some View {
        List {
            ConnectionBanner(model: model)
            if items.isEmpty, model.connection == .connected {
                ContentUnavailableView(reviewOnly ? "Nothing to review" : "No clips yet", systemImage: reviewOnly ? "checkmark.seal" : "film",
                                       description: Text(reviewOnly ? "New clips from the Mac show up here." : "Add a source on the Mac to start clipping."))
            }
            ForEach(items) { c in
                NavigationLink(value: c) { ClipRow(model: model, clip: c) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(reviewOnly ? "Review" : "All Clips")
        .navigationDestination(for: CompanionClip.self) { c in ClipDetail(model: model, id: c.id) }
        .refreshable { await model.refresh() }
        .task { if model.clips.isEmpty { await model.refresh() } }
    }
}

struct ConnectionBanner: View {
    var model: MobileModel
    var body: some View {
        switch model.connection {
        case .offline(let why):
            Label(why, systemImage: "wifi.exclamationmark").themeFont(.caption).foregroundStyle(.themeWarning).listRowBackground(Color.clear)
        case .searching:
            Label("Looking for \(model.macName)…", systemImage: "antenna.radiowaves.left.and.right").themeFont(.caption).foregroundStyle(.themeMuted).listRowBackground(Color.clear)
        case .connected:
            if let s = model.status, let running = s.running {
                Label("\(s.macName) is working on “\(running)”\(s.stage.map { " · \($0)" } ?? "")", systemImage: "gearshape.2").themeFont(.caption).foregroundStyle(.themeMuted).listRowBackground(Color.clear)
            }
        case .unpaired: EmptyView()
        }
    }
}

struct Thumb: View {
    var model: MobileModel
    let clip: CompanionClip
    @State var image: Image?
    var body: some View {
        ZStack {
            Color.black
            if let image { image.resizable().scaledToFill() } else { Image(systemName: "film").foregroundStyle(.white.opacity(0.5)) }
        }
        .task(id: clip.id) {
            #if canImport(UIKit)
            if let d = await model.thumbnail(clip), let ui = UIImage(data: d) { image = Image(uiImage: ui) }
            #endif
        }
    }
}

struct ClipRow: View {
    var model: MobileModel
    let clip: CompanionClip
    var body: some View {
        HStack(spacing: 12) {
            Thumb(model: model, clip: clip).frame(width: 56, height: 100).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(clip.title).themeFont(.callout, weight: .semibold).lineLimit(2)
                Text(clip.sourceTitle).themeFont(.caption).foregroundStyle(.themeMuted).lineLimit(1)
                HStack(spacing: 6) {
                    ThemeBadge(clip.statusLabel, feature: clip.needsReview ? .review : clip.status == "published" ? .publish : .highlights)
                    Text("\(clip.score) · \(Int(clip.duration)) s").themeFont(.caption, digits: true).foregroundStyle(.themeMuted)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(clip.needsReview ? .review : .highlights, padding: 0)
    }
}

struct ClipDetail: View {
    @Bindable var model: MobileModel
    let id: UUID
    @State var player: AVPlayer?
    @State var title = ""
    @State var rejecting = false
    @State var reason = ""
    @State var shareURL: URL?
    @Environment(\.dismiss) var dismiss

    var clip: CompanionClip? { model.clips.first { $0.id == id } }

    var body: some View {
        if let c = clip {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ZStack {
                        Thumb(model: model, clip: c)
                        if let player { VideoPlayer(player: player) }      // video is never tinted by the theme
                        else {
                            Button { Task { if let u = await model.video(c) { player = AVPlayer(url: u); player?.play() } } } label: {
                                Image(systemName: model.isBusy("video:\(c.id)") ? "arrow.down.circle" : "play.circle.fill").font(.system(size: 56)).foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            if model.isBusy("video:\(c.id)") { ProgressView().tint(.white).offset(y: 44) }
                        }
                    }
                    .aspectRatio(9 / 16, contentMode: .fit).frame(maxHeight: 460).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    HStack { ThemeBadge(c.statusLabel, feature: c.needsReview ? .review : .publish); Text("Score \(c.score)").themeFont(.caption, digits: true).foregroundStyle(.themeMuted) }
                    TextField("Title", text: $title, axis: .vertical).themeFont(.headline, display: true)
                        .onSubmit { Task { await model.setTitle(c, title) } }
                    if title != c.title { Button("Save title") { Task { await model.setTitle(c, title) } }.buttonStyle(.themed) }

                    VStack(alignment: .leading, spacing: 4) {
                        ThemeHeading("Why this clip")
                        Text(c.reason).themeFont(.callout).foregroundStyle(.themeMuted)
                    }.themedCard(.review)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            ThemeHeading("Title ideas")
                            Spacer()
                            Button(model.isBusy("titles:\(c.id)") ? "Writing…" : c.titleOptions.isEmpty ? "Suggest" : "Again") { Task { await model.suggestTitles(c) } }
                                .buttonStyle(.themed).disabled(model.isBusy("titles:\(c.id)"))
                        }
                        ForEach(c.titleOptions) { o in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: o.supported ? (o.recommended ? "star.fill" : "checkmark.circle") : "xmark.circle")
                                    .foregroundStyle(o.supported ? (o.recommended ? ThemeColor.themeWarning : ThemeColor.themeSuccess) : ThemeColor.themeDanger)
                                VStack(alignment: .leading) {
                                    Text(o.title).strikethrough(!o.supported).foregroundStyle(o.supported ? .themeText : .themeMuted)
                                    Text(o.supported ? o.hook.capitalized : "Rejected: \(o.problem ?? "")").themeFont(.caption).foregroundStyle(o.supported ? .themeMuted : .themeDanger)
                                }
                                Spacer()
                                if o.supported { Button("Use") { title = o.title; Task { await model.setTitle(c, o.title) } }.buttonStyle(.themed).controlSize(.small) }
                            }
                        }
                    }.themedCard(.publish)

                    if let e = c.lastError { Text(e).themeFont(.caption).foregroundStyle(.themeDanger) }

                    VStack(spacing: 10) {
                        if c.status != "published" {
                            Button(model.isBusy("publish:\(c.id)") ? "Publishing…" : "Approve & Publish to YouTube") { Task { await model.publish(c) } }
                                .buttonStyle(.themedPrimary).disabled(model.isBusy("publish:\(c.id)") || !(model.status?.youtubeSignedIn ?? false))
                            if !(model.status?.youtubeSignedIn ?? false) { Text("Sign in to YouTube on the Mac to publish.").themeFont(.caption).foregroundStyle(.themeMuted) }
                        }
                        HStack {
                            if c.needsReview { Button("Approve") { Task { await model.approve(c) } }.buttonStyle(.themed) }
                            Button("Save to Photos") { Task { await model.saveToPhotos(c) } }.buttonStyle(.themed)
                            Button { Task { shareURL = await model.video(c) } } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.themed)
                        }
                        if c.status != "published" { Button("Reject…", role: .destructive) { rejecting = true }.buttonStyle(.themed) }
                    }.frame(maxWidth: .infinity)
                }
                .padding()
            }
            .navigationTitle(c.sourceTitle).navigationBarTitleDisplayMode(.inline)
            .onAppear { title = c.title }
            .onChange(of: c.title) { _, t in title = t }
            .onDisappear { player?.pause() }
            .alert("Reject and delete this clip?", isPresented: $rejecting) {
                TextField("Reason (optional)", text: $reason)
                Button("Reject", role: .destructive) { Task { await model.reject(c, reason: reason); dismiss() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The Mac deletes the video and won't cut this moment again.") }
            .sheet(item: $shareURL) { u in ShareSheet(url: u).presentationDetents([.medium]) }
        } else {
            ContentUnavailableView("Clip removed", systemImage: "trash")
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: Stats

struct MobileStatsView: View {
    var model: MobileModel
    var body: some View {
        ScrollView {
            if let s = model.stats {
                let last28 = s.days.suffix(28), split = ChannelAnalytics.split(s.videos)
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        StatCard("Subscribers", s.subscribers.formatted(), "+\(last28.map(\.subscribers).reduce(0, +)) in 28 days", feature: .stats)
                        StatCard("Views · 28 days", last28.map(\.views).reduce(0, +).formatted(), feature: .highlights)
                        StatCard("Watch time", "\(Int(last28.map(\.minutes).reduce(0, +) / 60)) h", feature: .vlog)
                        StatCard("Videos", s.videoCount.formatted(), "\(split.shorts.count) Shorts", feature: .review)
                    }
                    VStack(alignment: .leading) {
                        ThemeHeading("Daily views")
                        Chart(s.days, id: \.day) { d in BarMark(x: .value("Day", ChannelAnalytics.parseDay(d.day) ?? .now, unit: .day), y: .value("Views", d.views)).foregroundStyle(.themeChart(0)) }
                            .frame(height: 160)
                    }.themedCard(.stats)
                    if !s.patterns.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ThemeHeading("What works on this channel")
                            ForEach(s.patterns, id: \.self) { Text("• " + $0).themeFont(.callout) }
                        }.themedCard()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ThemeHeading("Top videos")
                        ForEach(s.videos.sorted { $0.views > $1.views }.prefix(10)) { v in
                            HStack { Text(v.title).themeFont(.callout).lineLimit(1); Spacer(); Text(v.views.formatted()).themeFont(.callout, digits: true); Text(String(format: "%.0f%%", v.avgViewPercent)).themeFont(.caption, digits: true).foregroundStyle(.themeMuted) }
                        }
                    }.themedCard()
                    Text(ChannelAnalytics.unavailableNote).themeFont(.caption2).foregroundStyle(.themeMuted)
                }.padding()
            } else {
                ContentUnavailableView("No stats yet", systemImage: "chart.bar.xaxis", description: Text("Open Channel Stats on the Mac and sign in (read-only) once."))
            }
        }
        .navigationTitle(model.stats?.channelTitle ?? "Stats")
        .refreshable { await model.refresh() }
    }
}

// MARK: Upload

struct PickedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedVideo(url: dest)
        }
    }
}

struct MobileUploadView: View {
    @Bindable var model: MobileModel
    @State var item: PhotosPickerItem?
    @State var file: URL?
    @State var loading = false
    @State var title = ""
    @State var description = ""
    @State var tags = ""
    @State var privacy = "private"
    @State var owned = false
    @State var lastID: String?

    var body: some View {
        Form {
            Section {
                PhotosPicker(selection: $item, matching: .videos) { Label(file == nil ? "Choose a video" : "Choose another video", systemImage: "video.badge.plus") }
                if loading { HStack { ProgressView(); Text("Preparing video…") } }
                if let file { Text(file.lastPathComponent).themeFont(.caption).foregroundStyle(.themeMuted) }
            } footer: { Text("Your Mac uploads it to YouTube — the phone sends the file and never holds your YouTube sign-in.") }
            Section {
                TextField("Title (max 100)", text: $title)
                TextField("Description", text: $description, axis: .vertical).lineLimit(3...6)
                TextField("Tags, comma-separated", text: $tags)
                Picker("Visibility", selection: $privacy) { Text("Private").tag("private"); Text("Unlisted").tag("unlisted"); Text("Public").tag("public") }
            }
            Section {
                Toggle("I own this video or have the rights to upload it", isOn: $owned)
                Button(model.isBusy("upload") ? "Uploading…" : "Upload to YouTube") {
                    guard let file else { return }
                    Task { lastID = await model.upload(file, title: title, description: description, tags: tags, privacy: privacy, rightsConfirmed: owned) }
                }
                .buttonStyle(.themedPrimary)
                .disabled(file == nil || !owned || title.isEmpty || model.isBusy("upload") || model.connection != .connected)
                if let lastID { Link("Open in YouTube Studio", destination: URL(string: "https://studio.youtube.com/video/\(lastID)/edit")!) }
            }
        }
        .navigationTitle("Upload")
        .onChange(of: item) { _, new in
            guard let new else { return }
            loading = true
            Task {
                file = try? await new.loadTransferable(type: PickedVideo.self)?.url
                if title.isEmpty, let file { title = file.deletingPathExtension().lastPathComponent }
                loading = false
            }
        }
    }
}

// MARK: Settings

struct MobileSettingsView: View {
    @Bindable var model: MobileModel
    var body: some View {
        List {
            Section("Mac") {
                LabeledContent("Connected to", value: model.macName)
                LabeledContent("Status", value: model.connection == .connected ? "Online" : "Offline")
                Button("Refresh") { Task { await model.refresh() } }
                Button("Unpair this iPhone", role: .destructive) { model.unpair() }
            }
            Section("Appearance") {
                NavigationLink("Theme, mode, accent & effects") { AppearancePane(store: .shared).navigationTitle("Appearance") }
            }
        }
        .navigationTitle("Settings")
    }
}

#endif
