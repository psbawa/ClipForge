import CoreGraphics
import SwiftUI

/// Settings → Appearance: live preview cards, instant apply, mode / accent / effects, Surprise me.
public struct AppearancePane: View {
    @Bindable var store: ThemeStore
    public init(store: ThemeStore) { self.store = store }
    @Environment(\.theme) var current
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.colorSchemeContrast) var contrast

    var accentBinding: Binding<Color> {
        Binding(get: { store.accent.map { RGB($0).color } ?? current.color(.accent) },
                set: { c in
                    guard let cg = c.resolve(in: EnvironmentValues()).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
                          let k = cg.components, k.count >= 3 else { return }
                    func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
                    store.accent = (byte(k[0]) << 16) | (byte(k[1]) << 8) | byte(k[2])
                })
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    ForEach(Themes.all) { th in
                        Button { withAnimation(current.animation ?? .default) { store.themeID = th.id } } label: { ThemeCard(theme: th, store: store, selected: th.id == store.themeID) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(th.name) theme\(th.id == store.themeID ? ", selected" : "")")
                    }
                }
                Form {
                    Picker("Mode", selection: $store.mode) { ForEach(ThemeMode.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                    HStack {
                        Toggle("Custom accent color", isOn: Binding(get: { store.accent != nil }, set: { store.accent = $0 ? current.rgb(.accent).hex : nil }))
                        Spacer()
                        ColorPicker("", selection: accentBinding, supportsOpacity: false).labelsHidden().disabled(store.accent == nil)
                    }
                    Picker("Effects", selection: $store.effects) { ForEach(EffectsLevel.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                    HStack {
                        Button("Surprise me") { withAnimation(current.animation ?? .default) { store.surpriseMe() } }.buttonStyle(.themedPrimary)
                        Button("Reset") { store.themeID = Themes.neon.id; store.mode = .theme; store.accent = nil; store.effects = .full }.buttonStyle(.themed)
                    }
                    let notes = [reduceMotion ? "Reduce Motion: animations off" : nil,
                                 reduceTransparency ? "Reduce Transparency: glass and blur are solid" : nil,
                                 contrast == .increased ? "Increase Contrast: stronger text and borders" : nil,
                                 store.lowPower ? "Low Power Mode: grain, glow and blur paused" : nil].compactMap { $0 }
                    if !notes.isEmpty { Text("Following your Mac's settings — " + notes.joined(separator: " · ")).themeFont(.caption).foregroundStyle(.themeMuted) }
                }
                .formStyle(.grouped)
                .themedScrollBackground()
            }
            .padding()
        }
    }
}

/// A small, real render of the theme (its own palette/fonts/effects), not a screenshot.
struct ThemeCard: View {
    @Environment(\.theme) var current
    let theme: Theme
    var store: ThemeStore
    let selected: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.colorSchemeContrast) var contrast

    var body: some View {
        let r = ResolvedTheme.resolve(theme, dark: store.mode == .theme ? (theme.preferredScheme.map { $0 == .dark } ?? current.dark) : current.dark,
                                      accent: store.accent, level: store.effects, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency,
                                      increaseContrast: contrast == .increased, lowPower: store.lowPower)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach([Feature.review, .highlights, .story, .stats], id: \.self) { f in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(r.featureInk(f)).frame(width: 7, height: 7)
                            RoundedRectangle(cornerRadius: 2).fill(r.color(.muted).opacity(0.5)).frame(width: 26, height: 4)
                        }
                    }
                    Spacer()
                }.padding(6).frame(width: 46).background(r.color(.surface))
                VStack(alignment: .leading, spacing: 5) {
                    Text(r.heading("Clips")).themeFont(.caption, display: true).foregroundStyle(r.color(.text))
                    HStack(spacing: 5) {
                        ForEach([Feature.highlights, .review], id: \.self) { f in
                            VStack(alignment: .leading, spacing: 3) {
                                RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.3)).frame(height: 22)
                                ThemeBadge(f == .highlights ? "Ready" : "Review", feature: f).scaleEffect(0.8, anchor: .leading)
                            }.themedCard(f, padding: 4)
                        }
                    }
                    HStack { Spacer(); Text("Approve").font(.system(size: 8, weight: .semibold)).foregroundStyle(r.color(.onAccent)).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(r.color(.accent))) }
                }.padding(7)
            }
            .frame(height: 104)
            .background { ThemeBackdrop() }
            .clipped()
            VStack(alignment: .leading, spacing: 1) {
                Text(theme.name).themeFont(.callout, weight: .semibold).foregroundStyle(r.color(.text))
                Text(theme.tagline).themeFont(.caption2).foregroundStyle(r.color(.muted)).lineLimit(2, reservesSpace: true)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(r.color(.surface).opacity(1))
        }
        .environment(\.theme, r)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? r.color(.accent) : Color.gray.opacity(0.35), lineWidth: selected ? 3 : 1))
        .overlay(alignment: .topTrailing) { if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(r.color(.onAccent), r.color(.accent)).padding(5) } }
        .contentShape(Rectangle())
    }
}
