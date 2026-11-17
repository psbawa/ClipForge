import ClipForgeMobile
import SwiftUI

@main struct ClipForgeMobileApp: App {
    @State var model = MobileModel()
    @Environment(\.scenePhase) var phase

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
                .clipForgeTheme()
                .onChange(of: phase) { _, p in if p == .active { Task { await model.refresh() } } }
        }
    }
}
