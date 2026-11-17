import ClipForgeKit
import SwiftData
import SwiftUI

@main struct ClipForgeApp: App {
    @State var model: AppModel
    @State var story: StoryModel

    init() {
        do {
            let m = AppModel(container: try Store.container())
            _model = State(initialValue: m)
            _story = State(initialValue: m.makeStoryModel())
        } catch {
            fatalError("Could not open the ClipForge database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup("ClipForge") {
            RootView(model: model, story: story).frame(minWidth: 960, minHeight: 640).clipForgeTheme()
        }
        .modelContainer(model.container)
        .commands {
            CommandMenu("Pipeline") {
                Button("Stop") { model.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.runningSourceID == nil)
                Toggle("Block Auto-Publish (Kill Switch)", isOn: $model.settings.autoPublishKilled)
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
        Settings { SettingsView(model: model) }
    }
}
