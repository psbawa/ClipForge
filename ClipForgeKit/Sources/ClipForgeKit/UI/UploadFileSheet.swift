import SwiftUI
import UniformTypeIdentifiers

/// Upload any video from this Mac to YouTube (the other option: Download in Review and upload it yourself).
struct UploadFileSheet: View {
    var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var file: URL?
    @State var title = ""
    @State var description = ""
    @State var tags = ""
    @State var privacy = "private"
    @State var owned = false
    @State var busy = false
    @State var error: String?
    @State var videoID: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(file?.lastPathComponent ?? "No file chosen").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose Video…") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.movie]
                        if p.runModal() == .OK, let u = p.url {
                            file = u
                            if title.isEmpty { title = u.deletingPathExtension().lastPathComponent }
                            // A ClipForge download comes with a .txt (title, description, tags): use it.
                            if let meta = try? String(contentsOf: u.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8) {
                                let parts = meta.components(separatedBy: "\n\n")
                                title = parts.first ?? title
                                description = parts.dropFirst().first ?? ""
                            }
                        }
                    }
                }
            }
            Section {
                TextField("Title (max 100)", text: $title)
                TextField("Description", text: $description, axis: .vertical).lineLimit(3...8)
                TextField("Tags, comma-separated", text: $tags)
                Picker("Visibility", selection: $privacy) { Text("Private").tag("private"); Text("Unlisted").tag("unlisted"); Text("Public").tag("public") }
                Text("Vertical videos up to 3 minutes are treated as Shorts by YouTube.").themeFont(.caption).foregroundStyle(.themeMuted)
            }
            Section {
                Toggle("I own this video or have the rights to upload it", isOn: $owned)
                if let error { Text(error).foregroundStyle(.themeDanger).textSelection(.enabled) }
                if let videoID {
                    Link("Uploaded — open in YouTube Studio", destination: URL(string: "https://studio.youtube.com/video/\(videoID)/edit")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(videoID == nil ? "Cancel" : "Done") { dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? "Uploading…" : "Upload") {
                    guard let file else { return }
                    busy = true; error = nil
                    Task {
                        do {
                            videoID = try await model.uploadLocalFile(file, title: title, description: description,
                                                                      tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                                                      privacy: privacy, rightsConfirmed: owned)
                        } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }
                .disabled(file == nil || !owned || busy || videoID != nil || title.isEmpty)
            }
        }
        .onAppear { privacy = model.settings.privacyStatus }
    }
}
