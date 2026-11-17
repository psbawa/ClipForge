import SwiftUI
import UniformTypeIdentifiers

/// Shared Pro Editor control: Auto / a trend profile / "Edit like this reference", plus intensity.
struct StylePicker: View {
    @Binding var styleID: String?
    @Binding var intensity: Double
    var allowNone = false
    var analyze: ((URL, String) async throws -> StyleProfile)?
    @State var profiles: [StyleProfile] = []
    @State var busy = false
    @State var error: String?

    var selected: StyleProfile? { styleID.flatMap { id in profiles.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Editing style", selection: Binding(get: { styleID ?? "" }, set: { styleID = $0.isEmpty ? nil : $0 })) {
                Text("Auto (best for this content)").tag("")
                if allowNone { Text("None (plain)").tag("none") }
                ForEach(profiles) { p in Text(p.name + (p.origin == "reference" ? " · reference" : p.origin == "trend-refresh" ? " · refreshed" : "")).tag(p.id) }
            }
            if let p = selected {
                Text(p.summary).themeFont(.caption).foregroundStyle(.themeMuted)
                Text("\(p.platforms.joined(separator: ", ")) · ~\(Int(p.idealSeconds)) s · avg shot \(String(format: "%.1f", p.pacing.avgShotSeconds)) s · \(p.captions.style.label) captions · \(p.color) look")
                    .themeFont(.caption2).foregroundStyle(.themeMuted)
            }
            HStack {
                Text("Subtle").themeFont(.caption)
                Slider(value: $intensity, in: 0...1)
                Text("Aggressive").themeFont(.caption)
            }
            if let analyze {
                Button(busy ? "Analyzing reference…" : "Edit like a reference video…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = StoryConfig.videoTypes.compactMap { UTType(filenameExtension: $0) }
                    panel.message = "Pick a video you have the rights to analyze."
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    busy = true; error = nil
                    Task {
                        do {
                            let p = try await analyze(url, "Like " + url.deletingPathExtension().lastPathComponent)
                            profiles = StyleLibrary.all(); styleID = p.id
                        } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }.disabled(busy).controlSize(.small)
                if let error { Text(error).themeFont(.caption).foregroundStyle(.themeDanger) }
            }
        }
        .onAppear { profiles = StyleLibrary.all() }
    }
}

/// Settings → Pro Editor.
struct ProEditorPane: View {
    @Bindable var model: AppModel
    @State var status = ""
    @State var busy = false
    @State var profiles: [StyleProfile] = []

    var body: some View {
        Form {
            Section("Highlight clips") {
                StylePicker(styleID: $model.settings.clipStyleID, intensity: $model.settings.clipIntensity, allowNone: true,
                            analyze: model.story.map { s in { try await s.analyzeReference($0, name: $1) } })
            }
            Section("Gameplay clipper") {
                Picker("Game type", selection: $model.settings.gameGenre) {
                    Text("Auto-detect").tag("auto")
                    ForEach(GenreConfig.all, id: \.id) { Text($0.label).tag($0.id) }
                }
                Text("What counts as a moment: on-screen text (kills, wins, goals) and game sounds (gunfire, explosions, cheering) are weighted for this type of game.")
                    .themeFont(.caption).foregroundStyle(.themeMuted)
            }
            Section("Trends") {
                Toggle("Refresh trend profiles weekly (YouTube most-popular, read-only)", isOn: $model.settings.trendRefreshEnabled)
                LabeledContent("Last refresh", value: model.lastTrendRefresh?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                Button(busy ? "Refreshing…" : "Refresh now") {
                    busy = true
                    Task { status = await model.refreshTrends(force: true); profiles = StyleLibrary.all(); busy = false }
                }.disabled(busy)
                if !status.isEmpty { Text(status).themeFont(.caption).foregroundStyle(.themeMuted) }
                Text("TikTok/Reels trending sounds can't be fetched or embedded (they're licensed only inside those apps). ClipForge uses royalty-free music matched to the style's energy.")
                    .themeFont(.caption).foregroundStyle(.themeMuted)
            }
            Section("Profiles") {
                ForEach(profiles) { p in
                    VStack(alignment: .leading) {
                        Text(p.name).bold()
                        Text("\(p.origin) · version \(p.version) · \(StyleLibrary.history(p.id).count) version(s) kept").themeFont(.caption).foregroundStyle(.themeMuted)
                    }
                }
                Button("Open profiles folder") { NSWorkspace.shared.open(StyleLibrary.root) }
            }
        }
        .formStyle(.grouped)
        .onAppear { profiles = StyleLibrary.all() }
    }
}

/// Review screen: which style was applied, why, and switching it.
struct StyleReviewSection: View {
    @Bindable var model: AppModel
    @Bindable var clip: ClipRecord
    @State var styleID: String?
    @State var intensity = 0.5

    var job: StoryJob? { model.story?.job(clip.storyJobID) }
    var applied: String? { job?.storyboard?.styleID ?? clip.styleID }
    var notes: String? { job?.storyboard?.notes ?? clip.editorNotes }

    var body: some View {
        Section("Editing style") {
            LabeledContent("Applied", value: applied.flatMap(StyleLibrary.profile)?.name ?? "Plain (no style)")
            if let notes, !notes.isEmpty {
                Text("Why I edited it this way").themeFont(.caption, weight: .bold)
                Text(notes).themeFont(.caption).foregroundStyle(.themeMuted).textSelection(.enabled)
            }
            StylePicker(styleID: $styleID, intensity: $intensity, allowNone: job == nil,
                        analyze: model.story.map { s in { try await s.analyzeReference($0, name: $1) } })
            Button(job == nil ? "Apply style & re-render" : "Re-plan with this style") {
                Task { await model.applyStyle(clip, styleID: styleID == "none" ? nil : styleID, intensity: intensity) }
            }
            .disabled(model.voiceJobs[clip.id] != nil || clip.status == .rendering || (job?.isActive ?? false))
            Label("Trending sound: TikTok/Reels sounds are licensed only inside those apps — add one in-app when you post. This video uses royalty-free music.",
                  systemImage: "music.note").themeFont(.caption).foregroundStyle(.themeMuted)
        }
        .onAppear {
            styleID = applied
            intensity = job?.options.intensity ?? model.settings.clipIntensity
        }
    }
}
