import SwiftUI

/// Settings → iPhone: serve the companion app on the local network, pair phones, remove them.
struct CompanionPane: View {
    @Bindable var model: AppModel
    @State var now = Date()
    let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Allow the ClipForge iPhone app on this network", isOn: Binding(get: { model.settings.companionEnabled }, set: { model.setCompanion(enabled: $0) }))
                Text("Your iPhone can review, approve, publish and save clips, see Channel Stats and send videos to upload. The Mac does the work and keeps your API keys and YouTube sign-in; the phone only gets clips and results. Works while both are on the same Wi-Fi and ClipForge is open on the Mac.")
                    .themeFont(.caption).foregroundStyle(.themeMuted)
                if model.settings.companionEnabled {
                    LabeledContent("Status", value: model.companionPort.map { "Running on port \($0)" } ?? "Starting…")
                }
            }
            if model.settings.companionEnabled {
                Section("Pair an iPhone") {
                    if let code = model.companionPairCode, model.companionPairExpires > now {
                        HStack {
                            Text(code.prefix(3) + " " + code.suffix(3)).themeFont(.largeTitle, weight: .bold, mono: true).textSelection(.enabled)
                            Spacer()
                            Text("Expires in \(Int(model.companionPairExpires.timeIntervalSince(now))) s").themeFont(.caption).foregroundStyle(.themeMuted)
                        }
                        Text("Open ClipForge on the iPhone, pick this Mac and enter the code.").themeFont(.caption).foregroundStyle(.themeMuted)
                    } else {
                        Button("Pair iPhone…") { model.newPairCode() }.buttonStyle(.themedPrimary)
                    }
                }
                Section("Paired iPhones") {
                    if model.companionDevices.isEmpty { Text("None yet.").foregroundStyle(.themeMuted) }
                    ForEach(model.companionDevices) { d in
                        HStack {
                            Image(systemName: "iphone")
                            VStack(alignment: .leading) {
                                Text(d.name)
                                Text("Paired \(d.added.formatted(date: .abbreviated, time: .shortened))").themeFont(.caption).foregroundStyle(.themeMuted)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { model.unpair(d) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(tick) { now = $0 }
    }
}

extension AppModel {
    /// Called at launch: bring the companion back if it was on.
    public func resumeCompanion() { if settings.companionEnabled { startCompanion() } }
}
