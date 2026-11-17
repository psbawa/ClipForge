import SwiftUI
import UniformTypeIdentifiers

/// Edit a remix/story without re-analyzing: reorder (drag or arrows), trim, remove, swap a segment for another
/// suggested moment, change captions, music or style, then re-render. Saves to the job's edit plan.
struct RemixTimeline: View {
    @Bindable var story: StoryModel
    @Bindable var clip: ClipRecord
    @State var beats: [StoryBeat] = []
    @State var style: RemixStyle = .story
    @State var loadedFrom: Data?

    var job: StoryJob? { story.job(clip.storyJobID) }
    var dirty: Bool { job?.storyboard?.beats != beats }
    var running: Bool { job.map { $0.isActive } ?? false }

    var body: some View {
        Section("Timeline") {
            if let job {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(beats.enumerated()), id: \.element.id) { i, b in
                            card(i, b, job: job)
                                .draggable(String(i))
                                .dropDestination(for: String.self) { items, _ in
                                    guard let from = items.first.flatMap(Int.init), from != i, beats.indices.contains(from) else { return false }
                                    beats.move(fromOffsets: IndexSet(integer: from), toOffset: from < i ? i + 1 : i)
                                    return true
                                }
                        }
                    }.padding(.vertical, 4)
                }
                LabeledContent("Length", value: String(format: "%.1f s · %d segments", StoryTimeline.duration(beats), beats.count))
                Picker("Music", selection: Binding(get: { job.music?.path ?? "" }, set: { p in job.music = MusicLibrary.tracks().first { $0.path == p } })) {
                    if let m = job.music, !MusicLibrary.tracks().contains(m) { Text(m.name).tag(m.path) }
                    ForEach(MusicLibrary.tracks()) { Text($0.name).tag($0.path) }
                }
                HStack {
                    Picker("Style", selection: $style) { ForEach(RemixStyle.allCases) { Text($0.label).tag($0) } }
                    Button("Re-plan edit") {
                        var o = job.options; o.style = style; job.options = o
                        story.rewrite(job)
                    }.disabled(running).help("Ask Claude for a new edit in this style (uses the existing analysis)")
                }
                HStack {
                    Button(running ? "\(job.stage.label)…" : "Re-render remix") {
                        var sb = job.storyboard
                        sb?.beats = beats
                        job.storyboard = sb
                        story.rerender(job)
                    }
                    .buttonStyle(.themedPrimary)
                    .disabled(running || beats.count < 2)
                    if running { ProgressView().controlSize(.small) }
                    if dirty, !running { Text("Unsaved timeline changes").themeFont(.caption).foregroundStyle(.themeWarning) }
                }
                if job.stage == .failed, let e = job.errorMessage {
                    HStack { Text(e).themeFont(.caption).foregroundStyle(.themeDanger); Button("Retry") { story.retry(job) } }
                }
            } else {
                Text("The edit plan for this clip is missing.").foregroundStyle(.themeMuted)
            }
        }
        .onAppear(perform: load)
        .onChange(of: job?.storyboardData) { if !dirty || loadedFrom == nil { load() } }
    }

    func load() {
        guard let job, let sb = job.storyboard else { return }
        beats = sb.beats
        style = job.options.style
        loadedFrom = job.storyboardData
    }

    /// Unused candidate moments that don't overlap the current segments.
    func alternatives(_ job: StoryJob) -> [StoryMoment] {
        job.moments.filter { m in !beats.contains { min($0.end, m.end) - max($0.start, m.start) > 0.5 } }
    }

    func card(_ i: Int, _ b: StoryBeat, job: StoryJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            BeatThumb(video: job.video, time: (b.start + b.end) / 2, cache: job.folder.appendingPathComponent("thumbs"))
                .frame(width: 128, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    Text("\(i + 1)").themeFont(.caption2, weight: .bold).padding(4).background(.ultraThinMaterial, in: Circle()).padding(3)
                }
            Text("\(AppModel.clock(b.start)) · \(String(format: "%.1f", b.duration))s\(b.speed < 1 ? " · slow-mo" : "")")
                .themeFont(.caption2, digits: true).foregroundStyle(.themeMuted)
            Text(b.purpose).themeFont(.caption2, weight: .bold)
            TextField("Caption", text: $beats[i].caption).themeFont(.caption).frame(width: 128)
            HStack(spacing: 2) {
                trimButton("−", "Start earlier") { beats[i].start = max(0, beats[i].start - 0.5) }
                trimButton("+", "Start later") { if beats[i].duration > 1 { beats[i].start += 0.5 } }
                Text("|").foregroundStyle(.themeMuted)
                trimButton("−", "End earlier") { if beats[i].duration > 1 { beats[i].end -= 0.5 } }
                trimButton("+", "End later") { beats[i].end = min(job.duration, beats[i].end + 0.5) }
            }
            HStack(spacing: 6) {
                Button { if i > 0 { beats.swapAt(i, i - 1) } } label: { Image(systemName: "chevron.left") }.disabled(i == 0)
                Button { if i + 1 < beats.count { beats.swapAt(i, i + 1) } } label: { Image(systemName: "chevron.right") }.disabled(i + 1 == beats.count)
                Menu {
                    ForEach(alternatives(job), id: \.index) { m in
                        Button("\(AppModel.clock(m.start))–\(AppModel.clock(m.end)) · motion \(m.motion) · loud \(m.loudness)") {
                            let d = min(beats[i].duration, m.end - m.start)
                            beats[i].start = m.start + (m.end - m.start - d) / 2
                            beats[i].end = beats[i].start + d
                        }
                    }
                } label: { Image(systemName: "arrow.triangle.swap") }
                .menuIndicator(.hidden).fixedSize().help("Swap for another suggested moment")
                Button(role: .destructive) { beats.remove(at: i) } label: { Image(systemName: "trash") }.disabled(beats.count <= 2)
            }
            .buttonStyle(.borderless)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.themeRaised))
    }

    func trimButton(_ label: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(label, action: action).buttonStyle(.borderless).themeFont(.caption, weight: .bold).help(help)
    }
}

/// One frame of the source at `time`, cached as a small JPEG.
struct BeatThumb: View {
    var video: URL
    var time: Double
    var cache: URL
    @State var image: NSImage?
    var body: some View {
        ZStack { Rectangle().fill(.quaternary); if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) } }
            .task(id: time) {
                let file = cache.appendingPathComponent(String(format: "%.1f.jpg", time))
                if !FileManager.default.fileExists(atPath: file.path), let ffmpeg = Binaries.detect()?.ffmpeg {
                    try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                    try? await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-ss", String(format: "%.2f", time), "-i", video.path,
                                                  "-frames:v", "1", "-vf", "scale=256:-2", "-q:v", "6", file.path])
                }
                image = NSImage(contentsOf: file)
            }
    }
}
