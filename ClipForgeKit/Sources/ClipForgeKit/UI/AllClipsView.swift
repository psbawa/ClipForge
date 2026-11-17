import AVKit
import SwiftData
import SwiftUI

/// Every rendered video in one place: highlight clips from all sources + finished Story Shorts.
struct AllClipsView: View {
    @Bindable var model: AppModel
    static let pageID = UUID(uuidString: "A11C11E5-0000-4000-8000-000000000002")!

    enum Kind: String, CaseIterable { case all = "All", highlights = "Highlights", stories = "Story Shorts" }

    struct Item: Identifiable {
        var id: UUID
        var url: URL
        var title: String
        var subtitle: String
        var badge: String
        var date: Date
        var isStory: Bool
    }

    @Query var clips: [ClipRecord]
    @Query var stories: [StoryJob]
    @State var kind = Kind.all
    @State var search = ""
    @State var playing: Item?
    @State var reviewing: ClipRecord?

    var items: [Item] {
        let h = clips.compactMap { c in
            c.videoURL.map { Item(id: c.id, url: $0, title: c.title, subtitle: c.source?.title ?? "", badge: "\(c.effectiveScore) · \(c.status.label)", date: c.createdAt, isStory: false) }
        }
        let s = stories.compactMap { j in
            j.outputURL.map { Item(id: j.id, url: $0, title: j.storyboard?.title ?? j.name, subtitle: "Story Short · \(j.options.tone.rawValue)", badge: "\(Int(j.storyboard?.outputDuration ?? 0)) s", date: j.createdAt, isStory: true) }
        }
        return ((kind == .stories ? [] : h) + (kind == .highlights ? [] : s))
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.subtitle.localizedCaseInsensitiveContains(search) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 320)
                TextField("Search titles", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                Text("\(list.count) video\(list.count == 1 ? "" : "s") · hover to preview, click to play").foregroundStyle(.themeMuted).themeFont(.caption)
            }
            .padding()
            if list.isEmpty {
                ContentUnavailableView("No clips yet", systemImage: "play.rectangle.on.rectangle",
                                       description: Text("Highlight clips and finished Story Shorts appear here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                        ForEach(list) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                HoverPreview(url: item.url)
                                    .aspectRatio(9 / 16, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(alignment: .topTrailing) {
                                        ThemeBadge(item.badge, feature: item.isStory ? .story : .highlights).padding(6)
                                    }
                                    .overlay(alignment: .topLeading) {
                                        if item.isStory { Image(systemName: "wand.and.stars").padding(6).background(.ultraThinMaterial, in: Circle()).padding(6) }
                                    }
                                Text(item.title).themeFont(.callout, weight: .bold).lineLimit(2)
                                Text(item.subtitle).themeFont(.caption).foregroundStyle(.themeMuted).lineLimit(1)
                            }
                            .themedCard(item.isStory ? .story : .highlights, padding: 8)
                            .contentShape(Rectangle())
                            .onTapGesture { open(item) }
                            .overlay(alignment: .bottomTrailing) {
                                if !item.isStory { Button("Review") { open(item) }.controlSize(.small).padding(8) }
                            }
                        }
                    }
                    .padding([.horizontal, .bottom])
                }
            }
        }
        .sheet(item: $playing) { PreviewSheet(item: $0).themedSheet() }
        .sheet(item: $reviewing) { ReviewView(model: model, clip: $0).themedSheet() }
    }

    /// Highlight clips open the review screen; Story Shorts open the player.
    func open(_ item: Item) {
        if !item.isStory, let c = clips.first(where: { $0.id == item.id }) { reviewing = c } else { playing = item }
    }
}

/// Thumbnail at rest; plays muted and loops while the pointer is over it.
struct HoverPreview: View {
    var url: URL?
    @State var player: AVQueuePlayer?
    @State var looper: AVPlayerLooper?

    var body: some View {
        ZStack {
            Thumbnail(url: url)
            if let player { PlayerLayerView(player: player) }
            if let url, !FileManager.default.fileExists(atPath: url.path) {
                Label("File missing", systemImage: "exclamationmark.triangle").themeFont(.caption).padding(6).background(.ultraThinMaterial, in: Capsule())
            }
        }
        .onHover { inside in
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
            if inside {
                let p = AVQueuePlayer()
                p.isMuted = true
                looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url))
                player = p
                p.play()
            } else {
                player?.pause()
                looper = nil
                player = nil
            }
        }
        .onDisappear { player?.pause(); looper = nil; player = nil }
    }
}

/// AppKit's AVPlayerView with standard controls. Used instead of SwiftUI's VideoPlayer, whose
/// _AVKit_SwiftUI overlay aborted in Swift metadata setup on macOS 27.3 beta (getSuperclassMetadata).
struct PlayerView: NSViewRepresentable {
    var player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

/// Bare AVPlayerLayer (no controls) for inline previews.
struct PlayerLayerView: NSViewRepresentable {
    var player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let l = AVPlayerLayer(player: player)
        l.videoGravity = .resizeAspectFill
        v.layer = l
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { (v.layer as? AVPlayerLayer)?.player = player }
}

struct PreviewSheet: View {
    var item: AllClipsView.Item
    @Environment(\.dismiss) var dismiss
    @State var player = AVPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlayerView(player: player).frame(width: 360, height: 640).clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.title).themeFont(.headline, display: true).lineLimit(2).frame(width: 360, alignment: .leading)
            Text(item.subtitle).themeFont(.caption).foregroundStyle(.themeMuted)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .onAppear { player.replaceCurrentItem(with: AVPlayerItem(url: item.url)); player.play() }
        .onDisappear { player.pause() }
    }
}
