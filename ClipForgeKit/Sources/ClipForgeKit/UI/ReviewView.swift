import AVKit
import SwiftData
import SwiftUI

/// Review one clip: preview, why it was picked, edit metadata/captions/trim, then approve, reject or publish.
struct ReviewView: View {
    @Bindable var model: AppModel
    @Bindable var clip: ClipRecord
    @Environment(\.dismiss) var dismiss
    @State var player = AVPlayer()
    @State var start = 0.0
    @State var end = 0.0
    @State var style = CaptionStyle.pop
    @State var hashtags = ""
    @State var tags = ""
    @State var lines: [Line] = []
    @State var busy: String?
    @State var showReject = false
    @State var rejectReason = ""
    @State var setupFor: PublishPlatform?
    @State var debugURL: URL?
    @State var framingMode = 0          // 0 smart, 1 blur, 2 manual
    @State var manualX = 0.5

    struct Line: Identifiable, Equatable { let id = UUID(); var start: Double; var end: Double; var text: String; var original: String }

    var captionsEdited: Bool { lines.contains { $0.text != $0.original } }
    /// Edits that change the video itself and need a re-render before approving/publishing.
    var chosenFraming: Framing { framingMode == 1 ? .blur : framingMode == 2 ? .manual(manualX) : .smart }
    var needsRender: Bool {
        abs(start - clip.start) > 0.01 || abs(end - clip.end) > 0.01 || style != clip.captionStyle || captionsEdited || chosenFraming != clip.framing
    }
    var locked: Bool { [.publishing, .rendering].contains(clip.status) || busy != nil || model.voiceJobs[clip.id] != nil }
    /// Voiceover on but not generated from the current settings: the rendered video doesn't match what's shown.
    var voiceStale: Bool { clip.voiceover.enabled && clip.activeVoiceTrack == nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    PlayerView(player: player).frame(width: 300, height: 533).clipShape(RoundedRectangle(cornerRadius: 10))
                    statusBox
                    HStack {
                        Button(busy == "debug" ? "Rendering debug…" : "Debug Preview") { Task { await debugPreview() } }
                            .disabled(locked).help("Render the source with detected subjects, crop window and shot cuts drawn on it")
                        if let debugURL { Button("Open") { NSWorkspace.shared.open(debugURL) } }
                    }
                }
                .frame(width: 300)
                Form {
                    Section("Why this clip") {
                        Text("Picked because: \(clip.reason.isEmpty ? "—" : clip.reason)")
                        LabeledContent("Score", value: "signals \(clip.score) · final \(clip.finalScore.map(String.init) ?? "—")")
                        if !clip.hook.isEmpty { LabeledContent("Hook", value: clip.hook) }
                        let sig = clip.signals
                        if !sig.isEmpty {
                            ForEach(["vision", "watch", "hud", "events", "transcript", "audioPeak", "loudness", "motion", "scenes", "speech"], id: \.self) { k in
                                if let v = sig[k] {
                                    HStack {
                                        Text(Self.signalNames[k] ?? k).themeFont(.caption).frame(width: 120, alignment: .leading)
                                        ProgressView(value: Double(v), total: 100)
                                        Text("\(v)").themeFont(.caption, digits: true).frame(width: 28, alignment: .trailing)
                                    }
                                }
                            }
                        }
                    }
                    TitleOptionsSection(model: model, clip: clip)
                    if clip.storyJobID != nil, let story = model.story { RemixTimeline(story: story, clip: clip) }
                    if clip.storyJobID == nil { Section("Framing") {
                        Picker("Framing", selection: $framingMode) {
                            Text("Smart crop").tag(0); Text("Fit with blur").tag(1); Text("Manual position").tag(2)
                        }.pickerStyle(.segmented).labelsHidden()
                        if framingMode == 2 {
                            Slider(value: $manualX, in: 0...1) { Text("Crop position") } minimumValueLabel: { Text("Left") } maximumValueLabel: { Text("Right") }
                        }
                        if let f = clip.framingSummary { Text(f).themeFont(.caption).foregroundStyle(.themeMuted) }
                    } }
                    Section("Details") {
                        TextField("Title", text: $clip.title)
                        Text("\(clip.title.count)/100").themeFont(.caption).foregroundStyle(clip.title.count > 100 ? .themeDanger : .themeMuted)
                        TextEditor(text: $clip.descriptionText).frame(height: 80)
                        TextField("Hashtags", text: $hashtags, prompt: Text("#gaming #Shorts"))
                        TextField("Tags (comma separated)", text: $tags)
                    }
                    Section("Captions") {
                        if lines.isEmpty { Text("No speech in this clip.").foregroundStyle(.themeMuted) }
                        ForEach($lines) { $l in
                            HStack {
                                Text(String(format: "%.1fs", l.start - clip.start)).themeFont(.caption, digits: true).foregroundStyle(.themeMuted).frame(width: 44, alignment: .leading)
                                TextField("Caption", text: $l.text)
                            }
                        }
                    }
                    StyleReviewSection(model: model, clip: clip)
                    VoiceoverSection(model: model, clip: clip)
                    if clip.storyJobID == nil { Section("Trim & style") {
                        LabeledContent("Range", value: "\(AppModel.clock(start))–\(AppModel.clock(end)) · \(Int((end - start).rounded())) s")
                        Slider(value: $start, in: (clip.start - 15)...(clip.start + 15)) { Text("Start") }
                        Slider(value: $end, in: (clip.end - 15)...(clip.end + 15)) { Text("End") }
                        if clip.coreEnd > clip.coreStart, start > clip.coreStart + 0.05 || end < clip.coreEnd - 0.05 {
                            Label("This trim cuts into the moment that was scored (\(AppModel.clock(clip.coreStart))–\(AppModel.clock(clip.coreEnd))).",
                                  systemImage: "exclamationmark.triangle").themeFont(.caption).foregroundStyle(.themeWarning)
                        }
                        Picker("Caption style", selection: $style) { ForEach(CaptionStyle.allCases) { Text($0.label).tag($0) } }
                        Button(busy == "render" ? "Rendering…" : "Re-render") { Task { await rerender() } }
                            .disabled(!needsRender || locked || end - start < 3)
                    } }
                }
                .formStyle(.grouped)
                .frame(minWidth: 460)
            }
            .padding()
            Divider()
            actionBar.padding(12)
        }
        .frame(minWidth: 860, minHeight: 700)
        .onAppear(perform: load)
        .onChange(of: clip.videoPath) { reloadPlayer() }
        .onChange(of: model.voiceJobs[clip.id] == nil) { if model.voiceJobs[clip.id] == nil { reloadPlayer() } }
        .onDisappear { saveMeta(); player.pause() }
        .sheet(isPresented: $showReject) { rejectSheet.themedSheet() }
        .alert(setupFor.map { "\($0.name) isn't connected yet" } ?? "", isPresented: Binding(get: { setupFor != nil }, set: { if !$0 { setupFor = nil } })) {
            Button("OK") {}
        } message: { Text(setupFor?.setup ?? "") }
    }

    @ViewBuilder var statusBox: some View {
        HStack {
            Text(clip.status.label).themeFont(.caption, weight: .bold).padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(color(clip.status).opacity(0.2)))
            if clip.status == .rendering || clip.status == .publishing { ProgressView().controlSize(.small) }
            if let id = clip.videoID, let u = URL(string: "https://youtube.com/shorts/\(id)") { Link("Open on YouTube", destination: u).themeFont(.caption) }
        }
        if let e = clip.lastError {
            VStack(alignment: .leading, spacing: 6) {
                Text(e).themeFont(.caption).foregroundStyle(clip.status == .failed ? .themeDanger : .themeWarning).textSelection(.enabled)
                if clip.status == .failed { Button("Retry") { Task { busy = "retry"; await model.retry(clip); busy = nil; reloadPlayer() } }.disabled(locked) }
            }
        }
        if let p = clip.exportedPath { Button("Show download in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }.themeFont(.caption) }
    }

    var actionBar: some View {
        HStack {
            Button("Reject…", role: .destructive) { showReject = true }
                .disabled(locked || clip.status == .published)
            Spacer()
            if needsRender { Text("Re-render to apply trim/caption changes").themeFont(.caption).foregroundStyle(.themeWarning) }
            else if voiceStale { Text("Generate the voiceover (or turn it off) first").themeFont(.caption).foregroundStyle(.themeWarning) }
            Button("Approve") { saveMeta(); model.approve(clip) }
                .disabled(locked || needsRender || voiceStale || clip.status != .ready)
            Button("Approve & Download…") { saveMeta(); download() }
                .disabled(locked || needsRender || voiceStale || clip.videoURL == nil)
            Menu("Approve & Publish") {
                ForEach(PublishPlatform.allCases) { p in
                    Button(p.name + (p.isIntegrated ? "" : " (not connected)")) {
                        saveMeta()
                        if p.isIntegrated { Task { busy = "publish"; await model.approveAndPublish(clip); busy = nil } } else { setupFor = p }
                    }
                }
            }
            .fixedSize()
            .disabled(locked || needsRender || voiceStale || ![.ready, .approved, .downloaded].contains(clip.status))
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    var rejectSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reject and delete this clip?").themeFont(.headline, display: true)
            Text("The video file is deleted and this moment won't be cut again.").themeFont(.caption).foregroundStyle(.themeMuted)
            TextField("Reason (optional)", text: $rejectReason)
            HStack {
                Spacer()
                Button("Cancel") { showReject = false }
                Button("Reject & Delete", role: .destructive) {
                    showReject = false
                    player.pause()
                    let (c, r) = (clip, rejectReason)
                    dismiss()
                    // Delete after the screen is gone so no view reads the deleted record.
                    Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); model.reject(c, reason: r) }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 380)
    }

    static let signalNames = ["vision": "Claude (frames)", "transcript": "What's said", "audioPeak": "Audio spike",
                              "loudness": "Loudness", "motion": "Motion", "scenes": "Scene changes", "speech": "Speech energy",
                              "hud": "On-screen events", "events": "Game sounds", "watch": "Claude watched"]

    func color(_ s: ClipStatus) -> Color {
        switch s {
        case .ready: .orange
        case .approved, .downloaded: .blue
        case .published: .green
        case .failed: .red
        default: .secondary
        }
    }

    func load() {
        start = clip.start; end = clip.end; style = clip.captionStyle
        switch clip.framing {
        case .smart: framingMode = 0
        case .blur: framingMode = 1
        case .manual(let x): framingMode = 2; manualX = x
        }
        hashtags = clip.hashtags.map { $0.hasPrefix("#") ? $0 : "#" + $0 }.joined(separator: " ")
        tags = clip.tags.joined(separator: ", ")
        let words = (clip.captionWords ?? model.transcript(for: clip)).slice(clip.start, clip.end)
        lines = CaptionService.groups(words, clipStart: clip.start, clipEnd: clip.end).map { g in
            let t = g.words.joinedText
            return Line(start: clip.start + g.words.first!.start, end: clip.start + g.words.last!.end, text: t, original: t)
        }
        reloadPlayer()
    }

    func reloadPlayer() {
        if let u = clip.videoURL { player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: u))) }
    }

    func saveMeta() {
        clip.hashtags = hashtags.split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.hasPrefix("#") ? String($0) : "#" + $0 }
        clip.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        model.save()
    }

    /// Edited lines become new words spread evenly over the line's original timing.
    func applyCaptions() {
        guard captionsEdited else { return }
        var out: [Word] = []
        for l in lines {
            let parts = l.text.split(separator: " ").map(String.init)
            guard !parts.isEmpty else { continue }
            let step = (l.end - l.start) / Double(parts.count)
            out += parts.enumerated().map { i, w in Word(w, l.start + Double(i) * step, l.start + Double(i + 1) * step) }
        }
        clip.captionWords = out
        lines = lines.map { var l = $0; l.original = l.text; return l }
    }

    func rerender() async {
        saveMeta()
        applyCaptions()
        busy = "render"
        player.pause()
        clip.framing = chosenFraming
        await model.rerender(clip, start: start, end: end, style: style)
        start = clip.start; end = clip.end
        busy = nil
        reloadPlayer()
    }

    func debugPreview() async {
        busy = "debug"
        debugURL = await model.debugPreview(clip)
        busy = nil
        if let debugURL { NSWorkspace.shared.open(debugURL) }
    }

    func download() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Download Here"
        guard p.runModal() == .OK, let dir = p.url else { return }
        if let out = model.download(clip, to: dir) { NSWorkspace.shared.activateFileViewerSelecting([out]) }
    }
}

/// Every highlight clip with its status; bulk approve/reject/download/publish.
struct ReviewQueueView: View {
    static let pageID = UUID(uuidString: "2E71E000-0000-4000-8000-000000000003")!

    @Bindable var model: AppModel
    @Query(sort: \ClipRecord.createdAt, order: .reverse) var clips: [ClipRecord]
    @State var filter: ClipStatus? = .ready
    @State var selection = Set<UUID>()
    @State var reviewing: ClipRecord?
    @State var showReject = false
    @State var reason = ""

    var shown: [ClipRecord] { clips.filter { filter == nil || $0.status == filter } }
    var selected: [ClipRecord] { shown.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $filter) {
                    Text("Needs review (\(clips.filter { $0.status == .ready }.count))").tag(ClipStatus?.some(.ready))
                    ForEach([ClipStatus.approved, .failed, .downloaded, .published, .publishing, .rendering], id: \.self) { s in
                        Text("\(s.label) (\(clips.filter { $0.status == s }.count))").tag(ClipStatus?.some(s))
                    }
                    Text("All (\(clips.count))").tag(ClipStatus?.none)
                }
                .frame(width: 230)
                .onChange(of: filter) { selection = [] }
                Button(selection.count == shown.count && !shown.isEmpty ? "Deselect All" : "Select All") {
                    selection = selection.count == shown.count ? [] : Set(shown.map(\.id))
                }.disabled(shown.isEmpty)
                Spacer()
                Text("\(selection.count) selected").foregroundStyle(.themeMuted).themeFont(.caption)
                Button("Approve") { model.approveAll(selected) }.disabled(!selected.contains { $0.status == .ready })
                Button("Reject…", role: .destructive) { showReject = true }.disabled(selected.isEmpty)
                Button("Download…", action: downloadSelected).disabled(!selected.contains { $0.videoURL != nil })
                Button("Publish to YouTube") { Task { await model.publishAll(selected.filter { [.ready, .approved, .downloaded].contains($0.status) }) } }
                    .disabled(!selected.contains { [.ready, .approved, .downloaded].contains($0.status) })
            }
            .padding()
            if shown.isEmpty {
                ContentUnavailableView(filter == .ready ? "Nothing to review" : "No clips here", systemImage: "checkmark.circle",
                                       description: Text(filter == .ready ? "New highlight clips land here for one-click approval." : ""))
            } else {
                List(selection: $selection) {
                    ForEach(shown) { c in row(c).tag(c.id) }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count == 1, let c = shown.first(where: { ids.contains($0.id) }) { Button("Review…") { reviewing = c } }
                } primaryAction: { ids in
                    reviewing = shown.first { ids.contains($0.id) }
                }
            }
        }
        .sheet(item: $reviewing) { ReviewView(model: model, clip: $0).themedSheet() }
        .sheet(isPresented: $showReject) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Reject and delete \(selected.count) clip\(selected.count == 1 ? "" : "s")?").themeFont(.headline, display: true)
                Text("Their video files are deleted and these moments won't be cut again.").themeFont(.caption).foregroundStyle(.themeMuted)
                TextField("Reason (optional)", text: $reason)
                HStack {
                    Spacer()
                    Button("Cancel") { showReject = false }
                    Button("Reject & Delete", role: .destructive) {
                        let doomed = selected
                        selection = []
                        showReject = false
                        Task { @MainActor in try? await Task.sleep(for: .milliseconds(300)); model.rejectAll(doomed, reason: reason); reason = "" }
                    }
                }
            }
            .padding(20).frame(width: 380)
            .themedSheet()
        }
    }

    func row(_ c: ClipRecord) -> some View {
        HStack(spacing: 12) {
            Thumbnail(url: c.videoURL).frame(width: 45, height: 80).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(c.title).bold().lineLimit(1)
                Text("\(c.source?.title ?? "") · \(AppModel.clock(c.start))–\(AppModel.clock(c.end)) · \(Int(c.end - c.start)) s")
                    .themeFont(.caption).foregroundStyle(.themeMuted).lineLimit(1)
                if let e = c.lastError, c.status == .failed { Text(e).themeFont(.caption).foregroundStyle(.themeDanger).lineLimit(2) }
            }
            Spacer()
            Text("\(c.effectiveScore)").themeFont(.title3, weight: .bold, display: true, digits: true)
            Text(c.status.label).themeFont(.caption).frame(width: 90)
            if c.status == .failed { Button("Retry") { Task { await model.retry(c) } } }
            Button("Review") { reviewing = c }
        }
        .padding(.vertical, 4)
    }

    func downloadSelected() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Download Here"
        guard p.runModal() == .OK, let dir = p.url else { return }
        let n = selected.compactMap { model.download($0, to: dir) }.count
        model.notify("Downloaded \(n) clip\(n == 1 ? "" : "s") to \(dir.path).", .info)
    }
}

/// Hookable titles: 5 options by hook type, each fact-checked against the clip; rejected ones show why.
struct TitleOptionsSection: View {
    var model: AppModel
    @Bindable var clip: ClipRecord
    @State var busy = false

    var body: some View {
        Section("Title ideas") {
            HStack {
                Text(clip.titleOptions.isEmpty ? "Five hook titles, fact-checked against what the clip shows." : "Fact-checked against the transcript, detected events and frames.")
                    .themeFont(.caption).foregroundStyle(.themeMuted)
                Spacer()
                Button(busy ? "Writing…" : clip.titleOptions.isEmpty ? "Suggest Titles" : "Suggest Again") {
                    busy = true
                    Task { await model.suggestTitles(clip); busy = false }
                }.disabled(busy)
            }
            ForEach(clip.titleOptions) { o in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: o.supported ? (o.recommended ? "star.fill" : "checkmark.circle") : "xmark.circle")
                        .foregroundStyle(o.supported ? (o.recommended ? .themeWarning : .themeSuccess) : .themeDanger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.title).strikethrough(!o.supported).foregroundStyle(o.supported ? .themeText : .themeMuted)
                        Text(o.supported ? o.hook.capitalized : "Rejected: \(o.problem ?? "")").themeFont(.caption).foregroundStyle(o.supported ? .themeMuted : .themeDanger)
                    }
                    Spacer()
                    if o.supported { Button("Use") { model.useTitle(clip, o) }.disabled(clip.title == HighlightLogic.shortsTitle(o.title)) }
                }
            }
        }
    }
}
