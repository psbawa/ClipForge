import SwiftUI

public struct SettingsView: View {
    @Bindable var model: AppModel
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        TabView {
            AppearancePane(store: .shared).tabItem { Label("Appearance", systemImage: "paintpalette") }
            KeysPane(model: model).tabItem { Label("Accounts", systemImage: "key") }
            ModelsPane(s: $model.settings).tabItem { Label("Highlights", systemImage: "sparkles") }
            ClipsPane(s: $model.settings).tabItem { Label("Clips", systemImage: "scissors") }
            PublishPane(s: $model.settings).tabItem { Label("Publishing", systemImage: "paperplane") }
            ProEditorPane(model: model).tabItem { Label("Pro Editor", systemImage: "wand.and.rays") }
            CompanionPane(model: model).tabItem { Label("iPhone", systemImage: "iphone") }
        }
        .frame(width: 640, height: 600)
        .clipForgeTheme()
    }
}

struct KeysPane: View {
    @Bindable var model: AppModel
    @State var anthropic = ""
    @State var clientID = ""
    @State var clientSecret = ""
    @State var elevenLabs = ""
    @State var saved = false

    var body: some View {
        Form {
            Section("Anthropic") {
                SecureField("API key", text: $anthropic)
                Text("Stored in your macOS Keychain. Never written to disk or logs.").themeFont(.caption).foregroundStyle(.themeMuted)
            }
            Section("ElevenLabs (AI voiceover)") {
                SecureField("API key", text: $elevenLabs)
                Text("Optional. Without it, voiceovers use the free on-device Apple voices (incl. Indian English and Hindi).")
                    .themeFont(.caption).foregroundStyle(.themeMuted)
            }
            Section("Google OAuth client (Desktop app)") {
                TextField("Client ID", text: $clientID)
                SecureField("Client secret", text: $clientSecret)
                Text("Create a \"Desktop app\" OAuth client in Google Cloud Console with the YouTube Data API v3 enabled.")
                    .themeFont(.caption).foregroundStyle(.themeMuted)
            }
            YouTubeAccountSection(model: model)
            HStack {
                Spacer()
                if saved { Text("Saved").foregroundStyle(.themeMuted) }
                Button("Save") {
                    Keychain.set(anthropic, for: Keychain.Key.anthropic)
                    Keychain.set(clientID, for: Keychain.Key.googleClientID)
                    Keychain.set(clientSecret, for: Keychain.Key.googleClientSecret)
                    Keychain.set(elevenLabs, for: Keychain.Key.elevenLabs)
                    saved = true
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            anthropic = Keychain.get(Keychain.Key.anthropic) ?? ""
            clientID = Keychain.get(Keychain.Key.googleClientID) ?? ""
            clientSecret = Keychain.get(Keychain.Key.googleClientSecret) ?? ""
            elevenLabs = Keychain.get(Keychain.Key.elevenLabs) ?? ""
        }
    }
}

struct ModelsPane: View {
    @Binding var s: AppSettings
    var body: some View {
        Form {
            Section("Models") {
                TextField("Fast model (Stage A)", text: $s.fastModel)
                TextField("Strong model (Stage B)", text: $s.strongModel)
                TextField("Whisper model", text: $s.whisperModel)
            }
            Section("Scoring") {
                Stepper("Window: \(Int(s.windowSeconds)) s", value: $s.windowSeconds, in: 60...900, step: 30)
                Stepper("Score every: \(Int(s.stepSeconds)) s", value: $s.stepSeconds, in: 30...600, step: 15)
                Stepper("Stage B threshold: \(s.stageBThreshold)", value: $s.stageBThreshold, in: 0...100, step: 5)
            }
            Section("Budget & prices (USD per million tokens)") {
                TextField("Daily budget (0 = none)", value: $s.dailyBudgetUSD, format: .number)
                ForEach(Array(Set([s.fastModel, s.strongModel])).sorted(), id: \.self) { m in
                    HStack {
                        Text(m).frame(width: 160, alignment: .leading)
                        TextField("in", value: priceBinding(m, \.inputPerMTok), format: .number)
                        TextField("out", value: priceBinding(m, \.outputPerMTok), format: .number)
                    }
                }
                Text("Cache writes are billed at 1.25× and cache reads at 0.1× the input price.").themeFont(.caption).foregroundStyle(.themeMuted)
            }
        }.formStyle(.grouped)
    }

    func priceBinding(_ m: String, _ kp: WritableKeyPath<ModelPrice, Double>) -> Binding<Double> {
        Binding(get: { s.prices[m]?[keyPath: kp] ?? 0 },
                set: { var p = s.prices[m] ?? ModelPrice(0, 0); p[keyPath: kp] = $0; s.prices[m] = p })
    }
}

struct ClipsPane: View {
    @Binding var s: AppSettings
    var body: some View {
        Form {
            Section("Length") {
                Stepper("Minimum: \(Int(s.minClipSeconds)) s", value: $s.minClipSeconds, in: 5...60, step: 5)
                Stepper("Maximum: \(Int(s.maxClipSeconds)) s", value: $s.maxClipSeconds, in: 15...180, step: 1)
                Stepper("Pre-roll: \(s.preRoll, specifier: "%.1f") s", value: $s.preRoll, in: 0...5, step: 0.5)
                Stepper("Post-roll: \(s.postRoll, specifier: "%.1f") s", value: $s.postRoll, in: 0...5, step: 0.5)
                Text("Shorts must be 3 minutes or less; ClipForge never renders longer.").themeFont(.caption).foregroundStyle(.themeMuted)
            }
            Section("Per video") {
                Stepper("Always cut the best \(s.minClipsPerVideo) moment\(s.minClipsPerVideo == 1 ? "" : "s")", value: $s.minClipsPerVideo, in: 0...10)
                Text("Even if nothing clears the score thresholds. Auto-publish still needs its minimum score; the rest wait for review.")
                    .themeFont(.caption).foregroundStyle(.themeMuted)
            }
            Section("Captions") {
                Picker("Default style", selection: $s.captionStyle) { ForEach(CaptionStyle.allCases) { Text($0.label).tag($0) } }
            }
            Section("Live buffer") {
                Stepper("Keep last \(Int(s.bufferMinutes)) min of recording", value: $s.bufferMinutes, in: 10...240, step: 10)
            }
        }.formStyle(.grouped)
    }
}

struct PublishPane: View {
    @Binding var s: AppSettings
    var body: some View {
        Form {
            Section("Mode") {
                Picker("Publish mode", selection: $s.publishMode) {
                    Text("Review queue (one-click approval)").tag(PublishMode.review)
                    Text("Auto-publish within limits").tag(PublishMode.auto)
                }.pickerStyle(.radioGroup)
                Toggle("Kill switch: block all auto-publishing", isOn: $s.autoPublishKilled)
                Picker("Privacy", selection: $s.privacyStatus) {
                    Text("Private").tag("private"); Text("Unlisted").tag("unlisted"); Text("Public").tag("public")
                }
            }
            Section("Auto-publish limits") {
                Stepper("Max \(s.maxPerHour) per hour", value: $s.maxPerHour, in: 1...10)
                Stepper("Max \(s.maxPerDay) per day", value: $s.maxPerDay, in: 1...50)
                Stepper("Minimum score \(s.minAutoScore)", value: $s.minAutoScore, in: 50...100, step: 5)
                Stepper("At least \(Int(s.minGapMinutes)) min between uploads", value: $s.minGapMinutes, in: 0...240, step: 5)
                Text("Auto-publish is always off for sources from another channel unless you've recorded the rights holder's permission.")
                    .themeFont(.caption).foregroundStyle(.themeMuted)
            }
        }.formStyle(.grouped)
    }
}

struct YouTubeAccountSection: View {
    @Bindable var model: AppModel
    @State var busy = false
    var body: some View {
        Section("YouTube account") {
            if let c = model.youtubeChannel {
                LabeledContent("Channel", value: c.title)
                LabeledContent("Channel ID", value: c.id)
                Button("Sign Out") { Task { await model.signOutYouTube() } }
            } else {
                Text("Uploads go only to the channel you sign in with. Scopes: upload + read-only (to read your channel ID).")
                    .themeFont(.caption).foregroundStyle(.themeMuted)
                Button(busy ? "Waiting for browser…" : "Sign In with Google") {
                    busy = true
                    Task { await model.signInYouTube(); busy = false }
                }.disabled(busy)
            }
        }
        .task { await model.loadYouTubeChannel() }
    }
}
