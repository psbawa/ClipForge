import AVKit
import SwiftData
import SwiftUI

struct ClipsGalleryView: View {
    @Bindable var model: AppModel
    var source: Source
    @State var filter: ClipStatus?
    @State var editing: ClipRecord?

    var clips: [ClipRecord] {
        source.clips.filter { filter == nil || $0.status == filter }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $filter) {
                    Text("All").tag(ClipStatus?.none)
                    ForEach(ClipStatus.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }.frame(width: 200)
                Spacer()
                Button("Publish Approved") { Task { await model.publishApproved(source) } }
                    .disabled(!source.clips.contains { $0.status == .approved })
                Button("Export All…", action: export)
            }.padding(.horizontal).padding(.bottom, 8)
            if clips.isEmpty {
                ContentUnavailableView("No clips", systemImage: "rectangle.portrait.on.rectangle.portrait",
                                       description: Text("Highlights appear here after they're cut."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                        ForEach(clips) { c in ClipCard(clip: c) { editing = c }.onTapGesture { editing = c } }
                    }.padding()
                }
            }
        }
        .sheet(item: $editing) { ReviewView(model: model, clip: $0).themedSheet() }
    }

    func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let n = model.exportAll(to: dir)
        model.notify("Exported \(n) clip\(n == 1 ? "" : "s") to \(dir.path).", .info)
    }
}

struct ClipCard: View {
    var clip: ClipRecord
    var review: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HoverPreview(url: clip.videoURL)
                .aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    ThemeBadge("\(clip.effectiveScore)", feature: clip.status == .ready ? .review : .highlights).padding(6)
                }
                .overlay { if clip.status == .rendering { ProgressView() } }
            Text(clip.title).themeFont(.callout, weight: .bold).lineLimit(2)
            HStack {
                Text(clip.status.label).themeFont(.caption).foregroundStyle(clip.status == .failed ? .themeDanger : clip.status == .ready ? .themeWarning : .themeMuted)
                Text("· \(Int(clip.end - clip.start))s").themeFont(.caption).foregroundStyle(.themeMuted)
                Spacer()
                Button(clip.status == .ready ? "Review" : "Open", action: review).controlSize(.small)
            }
        }
        .themedCard(clip.status == .ready ? .review : .highlights, padding: 8)
        .contentShape(Rectangle())
    }
}

struct Thumbnail: View {
    var url: URL?
    @State var image: NSImage?
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 360, height: 640)
            if let cg = try? await gen.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image {
                image = NSImage(cgImage: cg, size: .zero)
            }
        }
    }
}
