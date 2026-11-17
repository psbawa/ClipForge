import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct VlogView: View {
    static let pageID = UUID(uuidString: "5701E5A0-0000-4000-8000-000000000002")!
    @Bindable var model: VlogModel
    @State var selected: UUID?
    @State var inputs: [URL] = []
    @State var options = VlogOptions()
    @State var owned = false
    @State var dropping = false
    @State var error: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView { form }.frame(maxHeight: 520)
                Divider()
                List(selection: $selected) {
                    ForEach(model.projects) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).lineLimit(1)
                            HStack(spacing: 4) {
                                if p.isActive && p.stage != .queued { ProgressView().controlSize(.mini) }
                                Text(p.stage.label).themeFont(.caption).foregroundStyle(p.stage == .failed ? .themeDanger : .themeMuted)
                            }
                        }
                        .tag(p.id)
                        .contextMenu { Button("Delete", role: .destructive) { model.delete(p.id) }.disabled(p.id == model.runningID) }
                    }
                }
                .listStyle(.inset)
            }
            .frame(width: 320)
            .padding(.vertical)
            Divider()
            if let p = model.projects.first(where: { $0.id == selected }) {
                VlogDetail(model: model, project: p).id(p.id)
            } else {
                ContentUnavailableView("Travel Vlog", systemImage: "map",
                                       description: Text("Drop a folder of trip videos and photos. ClipForge drops bad shots, groups the trip into chapters by day and place, and edits a full YouTube vlog and/or Shorts."))
            }
        }
    }

    var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Vlog").themeFont(.headline, display: true)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(dropping ? .themeAccent : .themeMuted)
                .frame(height: 70)
                .overlay {
                    VStack(spacing: 4) {
                        Text(inputs.isEmpty ? "Drop a footage folder or files" : inputs.count == 1 ? inputs[0].lastPathComponent : "\(inputs.count) items")
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: choose).controlSize(.small)
                    }.padding(.horizontal, 8)
                }
                .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                    for pr in providers {
                        _ = pr.loadObject(ofClass: URL.self) { u, _ in if let u { Task { @MainActor in inputs.append(u) } } }
                    }
                    return true
                }
            TextField("Trip title (optional)", text: $options.title)
            TextField("Places, e.g. Goa, Mumbai (optional)", text: $options.places)
            Picker("Vibe", selection: $options.vibe) { ForEach(VlogVibe.allCases) { Text($0.label).tag($0) } }
            Picker("Make", selection: $options.output) { ForEach(VlogOutput.allCases) { Text($0.label).tag($0) } }
            if options.output != .shorts {
                Stepper(options.fullMinutes == 0 ? "Vlog length: auto" : "Vlog length: \(Int(options.fullMinutes)) min",
                        value: $options.fullMinutes, in: 0...30, step: 1)
            }
            if options.output != .full {
                Stepper("Shorts: \(options.shortsCount)", value: $options.shortsCount, in: 1...8)
            }
            TextField("Direction (optional): e.g. focus on food, keep my talking parts", text: $options.prompt, axis: .vertical).lineLimit(2...4)
            Toggle("Delete proxies when done", isOn: $options.cleanupProxies).themeFont(.caption)
            Toggle("I shot this footage or have permission to use it", isOn: $owned).themeFont(.caption)
            if let error { Text(error).themeFont(.caption).foregroundStyle(.themeDanger) }
            Button("Create Vlog") {
                do { let p = try model.create(inputs: inputs, options: options); selected = p.id; inputs = []; error = nil }
                catch { self.error = error.localizedDescription }
            }
            .buttonStyle(.themedPrimary)
            .disabled(inputs.isEmpty || !owned)
        }
        .padding(.horizontal)
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .movie, .image]
        if panel.runModal() == .OK { inputs = panel.urls }
    }
}

struct VlogDetail: View {
    var model: VlogModel
    let project: VlogProject
    @State var playing: VlogOutputFile?
    @State var player = AVPlayer()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(project.name).themeFont(.title2, weight: .bold, display: true)
                    Spacer()
                    if project.isActive { Button("Cancel") { model.cancel(project.id) }.disabled(model.runningID != project.id) }
                    else {
                        Button("Retry") { model.retry(project.id) }.disabled(project.stage == .done)
                        Button("Re-plan Edit") { model.retry(project.id, replan: true) }
                    }
                }
                HStack(spacing: 8) {
                    Text(project.stage.label).foregroundStyle(project.stage == .failed ? .themeDanger : .themeMuted)
                    if model.runningID == project.id, let p = model.progress { ProgressView(value: p).frame(width: 200) }
                }
                if let e = project.error { Text(e).foregroundStyle(.themeDanger).textSelection(.enabled) }

                if !project.outputs.isEmpty {
                    if let playing {
                        PlayerView(player: player).frame(height: playing.isShort ? 420 : 300)
                    }
                    ForEach(project.outputs) { o in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label(o.title, systemImage: o.isShort ? "iphone" : "tv").themeFont(.headline, display: true)
                                    Spacer()
                                    Button("Play") { playing = o; player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: o.path))); player.play() }
                                    Button("Export…") { export(o) }
                                    Button("Copy Description") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(o.title + "\n\n" + o.description, forType: .string) }
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: o.path)]) } label: { Image(systemName: "folder") }
                                }
                                Text(o.description).themeFont(.caption).foregroundStyle(.themeMuted).textSelection(.enabled).lineLimit(8)
                            }
                        }
                    }
                }

                if !project.chapters.isEmpty {
                    Text("Chapters").themeFont(.headline, display: true)
                    ForEach(project.chapters, id: \.index) { c in
                        Text("\(c.title) — \(c.assetIDs.count) shots, \(c.start.formatted(date: .abbreviated, time: .shortened))").themeFont(.callout)
                    }
                }

                if !project.assets.isEmpty {
                    Text("Footage (\(project.assets.count - project.rejected.count) usable, \(project.rejected.count) dropped)").themeFont(.headline, display: true)
                    Text("Untick shots you don't want, then Re-plan Edit.").themeFont(.caption).foregroundStyle(.themeMuted)
                    ForEach(project.assets) { a in
                        HStack {
                            Toggle(isOn: Binding(get: { !project.options.excluded.contains(a.id) }, set: { on in
                                model.update(project.id) { o in if on { o.excluded.removeAll { $0 == a.id } } else { o.excluded.append(a.id) } }
                            })) { Text(a.name).lineLimit(1) }
                            .disabled(a.rejected != nil || project.isActive)
                            Spacer()
                            if let why = a.rejected { Text("Dropped: \(why)").themeFont(.caption).foregroundStyle(.themeWarning) }
                            else if a.talking { Text("Talking").themeFont(.caption).foregroundStyle(.themeMuted) }
                            Text(a.isPhoto ? "photo" : String(format: "%.0f s", a.duration)).themeFont(.caption, digits: true).foregroundStyle(.themeMuted)
                        }
                    }
                }
            }
            .padding()
        }
        .onDisappear { player.pause() }
    }

    func export(_ o: VlogOutputFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: o.path).lastPathComponent
        panel.allowedContentTypes = [.mpeg4Movie]
        if panel.runModal() == .OK, let url = panel.url { try? model.export(o, to: url) }
    }
}
