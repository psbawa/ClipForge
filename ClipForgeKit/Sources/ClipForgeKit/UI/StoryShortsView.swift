import AVKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct StoryShortsView: View {
    @Bindable var model: StoryModel
    @Query(sort: \StoryJob.createdAt, order: .reverse) var jobs: [StoryJob]
    @State var selected: UUID?
    @State var video: URL?
    @State var options = StoryOptions()
    @State var error: String?
    @State var dropping = false
    @State var owned = false
    @State var customLength = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView { newJob }.frame(maxHeight: 470)
                Divider()
                List(selection: $selected) {
                    ForEach(jobs) { j in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(j.storyboard?.title ?? j.name).lineLimit(1)
                            HStack(spacing: 4) {
                                if j.isActive && j.stage != .queued { ProgressView().controlSize(.mini) }
                                Text(j.stage.label).themeFont(.caption).foregroundStyle(j.stage == .failed ? .themeDanger : .themeMuted)
                            }
                        }
                        .tag(j.id)
                        .contextMenu { Button("Delete", role: .destructive) { model.delete(j) }.disabled(j.id == model.runningJobID) }
                    }
                }
                .listStyle(.inset)
            }
            .frame(width: 300)
            .padding(.vertical)
            Divider()
            if let j = jobs.first(where: { $0.id == selected }) {
                StoryJobDetail(model: model, job: j).id(j.id)
            } else {
                ContentUnavailableView("Story Shorts", systemImage: "wand.and.stars",
                                       description: Text("Drop a gameplay video on the left. ClipForge finds the best moments, writes a hook → build-up → climax → payoff story, adds captions and music, and renders a 9:16 short."))
            }
        }
    }

    var newJob: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Story or Remix").themeFont(.headline, display: true)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(dropping ? .themeAccent : .themeMuted)
                .frame(height: 70)
                .overlay {
                    VStack(spacing: 4) {
                        Text(video?.lastPathComponent ?? "Drop a gameplay video").lineLimit(1).truncationMode(.middle)
                        Button("Choose Video…", action: choose).controlSize(.small)
                    }.padding(.horizontal, 8)
                }
                .onDrop(of: [.fileURL], isTargeted: $dropping) { items in
                    _ = items.first?.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in video = url } }
                    }
                    return true
                }
            Picker("Style", selection: $options.style) { ForEach(RemixStyle.allCases) { Text($0.label).tag($0) } }
            Picker("Format", selection: $options.format) { ForEach(OutputFormat.allCases) { Text($0.label).tag($0) } }
            TextField("Game (optional)", text: $options.gameName)
            TextField("Direction (optional), e.g. only clutch moments", text: $options.prompt, axis: .vertical).lineLimit(1...3)
            Picker("Length", selection: Binding(get: { customLength ? -1 : options.targetSeconds }, set: { v in
                customLength = v < 0
                if v > 0 { options.targetSeconds = v }
            })) {
                ForEach(StoryConfig.lengths, id: \.self) { Text("\(Int($0))s").tag($0) }
                Text("Custom").tag(-1.0)
            }.pickerStyle(.segmented)
            if customLength {
                Stepper("Length: \(Int(options.targetSeconds)) s", value: $options.targetSeconds, in: 10...180, step: 5)
            }
            Picker("Tone", selection: $options.tone) { ForEach(StoryTone.allCases) { Text($0.rawValue.capitalized).tag($0) } }
            Picker("Captions", selection: $options.captionStyle) { ForEach(CaptionStyle.allCases) { Text($0.label).tag($0) } }
            Picker("Framing", selection: $options.cropMode) {
                Text("Auto").tag(StoryCropMode.auto); Text("Smart crop").tag(StoryCropMode.smart); Text("Blur fill").tag(StoryCropMode.blur)
            }
            StylePicker(styleID: $options.styleID, intensity: $options.intensity, analyze: { try await model.analyzeReference($0, name: $1) })
            Toggle("Word-by-word subtitles for speech", isOn: $options.subtitles)
            Toggle("I own this footage or have permission to use it", isOn: $owned).themeFont(.caption)
            if let error { Text(error).themeFont(.caption).foregroundStyle(.themeDanger) }
            Button(options.style == .story ? "Create Story Short" : "Create Remix") {
                guard let video else { return }
                do { let j = try model.create(video: video, options: options); selected = j.id; self.video = nil; error = nil }
                catch { self.error = error.localizedDescription }
            }
            .buttonStyle(.themedPrimary)
            .disabled(video == nil || !owned)
        }
        .padding(.horizontal)
    }

    func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = StoryConfig.videoTypes.compactMap { UTType(filenameExtension: $0) }
        if p.runModal() == .OK { video = p.url }
    }
}

struct StoryJobDetail: View {
    @Bindable var model: StoryModel
    @Bindable var job: StoryJob
    @State var player = AVPlayer()
    @State var sb: Storyboard?
    @State var tracks: [MusicTrack] = []
    @State var exportError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                stages
                if job.stage == .failed {
                    GroupBox {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.themeDanger)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(job.failedStage?.label ?? "A stage") failed").bold()
                                Text(job.errorMessage ?? "Unknown error").textSelection(.enabled)
                            }
                            Spacer()
                            Button("Retry") { model.retry(job) }
                        }
                    }
                }
                if job.stage == .done || job.outputURL != nil {
                    HStack(alignment: .top, spacing: 18) {
                        PlayerView(player: player).frame(width: 270, height: 480).clipShape(RoundedRectangle(cornerRadius: 10))
                        editor
                    }
                }
            }
            .padding()
        }
        .onAppear(perform: load)
        .onChange(of: job.stageRaw) { _, s in if s == StoryStage.done.rawValue { load() } }
        .onDisappear { player.pause() }
    }

    var stages: some View {
        HStack(spacing: 6) {
            ForEach(StoryStage.pipeline + [.done], id: \.self) { s in
                let current = job.stage == s && job.isActive
                let failed = job.stage == .failed && job.failedStage == s
                let finished = job.stage == .done || (s.order < (job.stage == .failed ? job.failedStage?.order ?? 0 : job.stage.order))
                HStack(spacing: 4) {
                    if current { ProgressView().controlSize(.mini) }
                    else if failed { Image(systemName: "xmark.circle.fill") }
                    else if finished { Image(systemName: "checkmark.circle.fill") }
                    Text(s.label)
                }
                .themeFont(.caption, weight: .bold)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(failed ? ThemeColor.themeDanger : current ? ThemeColor.themeAccent : finished ? ThemeColor.themeSuccess.opacity(0.25) : ThemeColor.themeRaised))
                .foregroundStyle(failed || current ? .themeOnAccent : .themeText)
            }
            if job.isActive {
                if let p = model.progress, job.id == model.runningJobID { ProgressView(value: p).frame(width: 90) }
                Spacer()
                Button("Cancel", role: .destructive) { model.cancel(job) }
            }
        }
    }

    @ViewBuilder var editor: some View {
        if let sb = Binding($sb) {
            Form {
                Section("Story") {
                    ForEach(sb.beats) { $b in
                        HStack {
                            Text(b.purpose.capitalized).themeFont(.caption, weight: .bold).frame(width: 64, alignment: .leading)
                            Text(String(format: "%.1f–%.1fs", b.start, b.end)).themeFont(.caption, digits: true).foregroundStyle(.themeMuted).frame(width: 90)
                            TextField("Caption", text: $b.caption)
                        }
                    }
                }
                Section("Music") {
                    Picker("Track", selection: Binding(get: { job.music?.path ?? "" }, set: { p in job.music = tracks.first { $0.path == p } })) {
                        ForEach(tracks) { Text($0.name).tag($0.path) }
                    }
                    HStack {
                        Button("Use My Own Track…", action: chooseTrack)
                        Button("Open Music Folder") { NSWorkspace.shared.open(StoryConfig.musicRoot) }
                    }
                    if job.music?.isPlaceholder == true {
                        Text("This is a generated placeholder. Add royalty-free or licensed tracks to ~/Music/ClipForge/<mood>/ and they'll be picked automatically.")
                            .themeFont(.caption).foregroundStyle(.themeWarning)
                    }
                }
                Section("Upload details") {
                    TextField("Title", text: sb.title)
                    TextEditor(text: sb.description).frame(height: 70)
                    TextField("Hashtags", text: Binding(get: { sb.wrappedValue.hashtags.joined(separator: " ") },
                                                        set: { sb.wrappedValue.hashtags = $0.split(separator: " ").map(String.init) }))
                }
                Section {
                    HStack {
                        Button("Re-render") { saveEdits(); model.rerender(job) }.disabled(job.isActive)
                        Button("Rewrite Story") { model.rewrite(job) }.disabled(job.isActive)
                            .help("Ask Claude for a new storyboard (new API call)")
                        Spacer()
                        if let u = job.outputURL { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                        Button("Export…", action: export).buttonStyle(.themedPrimary).disabled(job.outputURL == nil || job.isActive)
                    }
                    if let exportError { Text(exportError).foregroundStyle(.themeDanger).themeFont(.caption) }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 460)
        }
    }

    func load() {
        sb = job.storyboard
        tracks = MusicLibrary.tracks()
        if let m = job.music, !tracks.contains(m) { tracks.append(m) }
        if let u = job.outputURL { player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: u))) }
    }

    func saveEdits() { if let sb { job.storyboard = sb; model.save() } }

    func chooseTrack() {
        let p = NSOpenPanel()
        p.allowedContentTypes = MusicLibrary.audioTypes.compactMap { UTType(filenameExtension: $0) }
        p.message = "Only use music you have the rights to (royalty-free or licensed)."
        guard p.runModal() == .OK, let u = p.url else { return }
        let t = MusicTrack(path: u.path, mood: nil, isPlaceholder: false)
        if !tracks.contains(t) { tracks.append(t) }
        job.music = t
    }

    func export() {
        saveEdits()
        let p = NSSavePanel()
        p.allowedContentTypes = [.mpeg4Movie]
        p.nameFieldStringValue = (job.storyboard?.title ?? job.name).replacingOccurrences(of: "/", with: "-") + ".mp4"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try model.export(job, to: url); exportError = nil } catch { exportError = error.localizedDescription }
    }
}
