import CoreText
import Foundation
import Observation
import SwiftUI

public enum ThemeMode: String, CaseIterable, Identifiable, Sendable {
    case theme, system, light, dark
    public var id: String { rawValue }
    public var label: String { ["theme": "Theme default", "system": "Match system", "light": "Light", "dark": "Dark"][rawValue]! }
}

public enum EffectsLevel: String, CaseIterable, Identifiable, Sendable {
    case off, subtle, full
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    var opacity: Double { [.off: 0, .subtle: 0.5, .full: 1][self]! }
}

/// The user's appearance choices (UserDefaults; no account sync exists) + live system state.
@MainActor @Observable public final class ThemeStore {
    public static let shared = ThemeStore()
    static let keys = (theme: "appearance.theme", mode: "appearance.mode", effects: "appearance.effects", accent: "appearance.accent")

    public var themeID: String { didSet { UserDefaults.standard.set(themeID, forKey: Self.keys.theme) } }
    public var mode: ThemeMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.keys.mode) } }
    public var effects: EffectsLevel { didSet { UserDefaults.standard.set(effects.rawValue, forKey: Self.keys.effects) } }
    /// Accent override as 0xRRGGBB; nil = the theme's own accent.
    public var accent: UInt32? { didSet { UserDefaults.standard.set(accent.map { Int($0) }, forKey: Self.keys.accent) } }
    public private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored var observers: [NSObjectProtocol] = []

    init() {
        let d = UserDefaults.standard
        themeID = d.string(forKey: Self.keys.theme).flatMap { id in Themes.all.contains { $0.id == id } ? id : nil } ?? Themes.neon.id
        mode = d.string(forKey: Self.keys.mode).flatMap(ThemeMode.init(rawValue:)) ?? .theme
        effects = d.string(forKey: Self.keys.effects).flatMap(EffectsLevel.init(rawValue:)) ?? .full
        accent = (d.object(forKey: Self.keys.accent) as? Int).map { UInt32($0) }
        Self.registerFonts()
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })
    }

    public var theme: Theme { Themes.all.first { $0.id == themeID } ?? Themes.neon }

    /// The appearance this choice forces on the window, or nil to follow the system (read from the environment).
    public var forcedDark: Bool? {
        switch mode {
        case .light: false
        case .dark: true
        case .system: nil
        case .theme: theme.preferredScheme.map { $0 == .dark }
        }
    }

    public func surpriseMe() {
        themeID = (Themes.all.filter { $0.id != themeID }.randomElement() ?? Themes.neon).id
        mode = [.theme, .theme, .light, .dark].randomElement()!
        accent = Bool.random() ? nil : [0xFF3DCB, 0x3DE0FF, 0xFF8A3D, 0xA58BFF, 0xC6FF3D].randomElement()
    }

    /// Bundled OFL fonts live in the package's resource bundle (not the app's Resources), so they're registered at launch
    /// for this process instead of via Info.plist's ATSApplicationFontsPath.
    nonisolated static func bundled(_ ext: String) -> [URL] { Bundle.module.urls(forResourcesWithExtension: ext, subdirectory: "Fonts") ?? [] }

    public static func registerFonts() {
        for url in bundled("ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

/// The theme as views see it: one palette (light or dark) with accessibility and power rules already applied.
public struct ResolvedTheme: Sendable {
    public var theme: Theme
    public var p: Palette
    public var dark: Bool
    public var effects: Effects
    public var effectsOpacity: Double
    public var reduceMotion: Bool
    public var solidSurfaces: Bool
    public var borderWidth: Double

    public static let fallback = ResolvedTheme(theme: Themes.minimal, p: Themes.minimal.light, dark: false, effects: [], effectsOpacity: 0,
                                               reduceMotion: true, solidSurfaces: true, borderWidth: 1)

    public init(theme: Theme, p: Palette, dark: Bool, effects: Effects, effectsOpacity: Double, reduceMotion: Bool, solidSurfaces: Bool, borderWidth: Double) {
        self.theme = theme; self.p = p; self.dark = dark; self.effects = effects; self.effectsOpacity = effectsOpacity
        self.reduceMotion = reduceMotion; self.solidSurfaces = solidSurfaces; self.borderWidth = borderWidth
    }

    public static func resolve(_ t: Theme, dark: Bool, accent: UInt32?, level: EffectsLevel, reduceMotion: Bool,
                               reduceTransparency: Bool, increaseContrast: Bool, lowPower: Bool) -> ResolvedTheme {
        var p = dark ? t.dark : t.light
        if let accent {
            p.accent = RGB(accent)
            p.onAccent = RGB.contrast(RGB(0x000000), p.accent) >= RGB.contrast(RGB(0xFFFFFF), p.accent) ? RGB(0x0B0B0F) : RGB(0xFFFFFF)
        }
        var fx = level == .off ? [] : t.effects
        let solid = reduceTransparency || lowPower
        if reduceTransparency { fx.subtract([.glass, .blobs, .grain]) }
        if lowPower { fx.subtract([.grain, .glow, .blobs, .glass]) }          // heavy effects off in Low Power Mode
        if solid { p.surface.alpha = 1; p.raised.alpha = 1 }
        if increaseContrast { p.muted = p.text; p.border = RGB(p.text.hex) }
        return ResolvedTheme(theme: t, p: p, dark: dark, effects: fx, effectsOpacity: level.opacity, reduceMotion: reduceMotion,
                             solidSurfaces: solid, borderWidth: t.border + (increaseContrast ? 1 : 0))
    }

    // MARK: Lookups

    public enum Role: Sendable, Hashable { case canvas, surface, raised, text, muted, border, accent, onAccent, success, warning, danger, onFeature, feature(Feature), ink(Feature), chart(Int) }

    public func rgb(_ r: Role) -> RGB {
        switch r {
        case .canvas: p.canvas
        case .surface: p.surface
        case .raised: p.raised
        case .text: p.text
        case .muted: p.muted
        case .border: p.border
        case .accent: p.accent
        case .onAccent: p.onAccent
        case .success: p.success
        case .warning: p.warning
        case .danger: p.danger
        case .onFeature: p.onFeature
        case .feature(let f): p.feature[f] ?? p.accent
        case .ink(let f): dark ? (p.feature[f] ?? p.accent) : p.muted
        case .chart(let i): p.chart[((i % p.chart.count) + p.chart.count) % p.chart.count]
        }
    }
    public func color(_ r: Role) -> Color { rgb(r).color }

    /// Feature color for icons/text on surfaces: light modes use muted ink (pastel/neon fills fail 3:1 on light backgrounds).
    public func featureInk(_ f: Feature) -> Color { color(.ink(f)) }

    public var radius: Double { theme.radius }
    public func heading(_ s: String) -> String { theme.type.uppercaseHeadings ? s.uppercased() : s }

    public func font(_ style: Font.TextStyle, weight: Font.Weight? = nil, display: Bool = false, mono: Bool = false) -> Font {
        let face = display ? theme.type.display : mono ? theme.type.mono : theme.type.body
        let w = weight ?? (display ? theme.type.displayWeight : nil)
        switch face {
        case .system(let design):
            var f = Font.system(style, design: design)
            if let w { f = f.weight(w) }
            return f
        case .custom(let family):
            let scale = display ? theme.type.displayScale : 1
            // Pixel fonts turn to mush below ~9.5 pt: small labels use the body face instead.
            if family == "Press Start 2P", Self.size(style) * scale < 9.5 { return font(style, weight: weight, display: false, mono: mono) }
            var f = Font.custom(family, size: Self.size(style) * scale, relativeTo: style)
            if let w, family != "Press Start 2P" { f = f.weight(w) }
            return f
        }
    }

    static func size(_ s: Font.TextStyle) -> Double {
        switch s {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote: 10
        case .caption: 10
        case .caption2: 10
        @unknown default: 13
        }
    }

    public var animation: Animation? {
        guard !reduceMotion else { return nil }
        switch theme.motion {
        case .none: return nil
        case .gentle: return .easeInOut(duration: 0.3)
        case .bouncy: return .spring(response: 0.4, dampingFraction: 0.65)
        case .snappy: return .snappy(duration: 0.22)
        }
    }
}

public extension EnvironmentValues {
    @Entry var theme: ResolvedTheme = .fallback
}

/// Theme colors as a ShapeStyle, resolved from the environment — `.foregroundStyle(.themeMuted)` needs no @Environment in the view.
public struct ThemeColor: ShapeStyle {
    let role: ResolvedTheme.Role
    var opacity = 1.0
    public func resolve(in env: EnvironmentValues) -> Color { env.theme.color(role).opacity(opacity) }
    public func opacity(_ o: Double) -> ThemeColor { ThemeColor(role: role, opacity: opacity * o) }
}

public extension ShapeStyle where Self == ThemeColor {
    static var themeText: ThemeColor { ThemeColor(role: .text) }
    static var themeMuted: ThemeColor { ThemeColor(role: .muted) }
    static var themeAccent: ThemeColor { ThemeColor(role: .accent) }
    static var themeOnAccent: ThemeColor { ThemeColor(role: .onAccent) }
    static var themeSurface: ThemeColor { ThemeColor(role: .surface) }
    static var themeRaised: ThemeColor { ThemeColor(role: .raised) }
    static var themeCanvas: ThemeColor { ThemeColor(role: .canvas) }
    static var themeBorder: ThemeColor { ThemeColor(role: .border) }
    static var themeSuccess: ThemeColor { ThemeColor(role: .success) }
    static var themeWarning: ThemeColor { ThemeColor(role: .warning) }
    static var themeDanger: ThemeColor { ThemeColor(role: .danger) }
    static var themeOnFeature: ThemeColor { ThemeColor(role: .onFeature) }
    static func themeFeature(_ f: Feature) -> ThemeColor { ThemeColor(role: .feature(f)) }
    static func themeChart(_ i: Int) -> ThemeColor { ThemeColor(role: .chart(i)) }
    /// Feature color for icons on surfaces (muted ink in light modes, where neon/pastel fills fail 3:1).
    static func themeInk(_ f: Feature) -> ThemeColor { ThemeColor(role: .ink(f)) }
}

struct ThemeFontModifier: ViewModifier {
    @Environment(\.theme) var theme
    let style: Font.TextStyle; let weight: Font.Weight?; let display: Bool; let mono: Bool; let digits: Bool
    func body(content: Content) -> some View {
        let f = theme.font(style, weight: weight, display: display, mono: mono)
        content.font(digits ? f.monospacedDigit() : f)
    }
}

public extension View {
    /// Theme typography: `display` for headings, `mono` for code/numbers, `digits` for aligned numbers.
    func themeFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, display: Bool = false, mono: Bool = false, digits: Bool = false) -> some View {
        modifier(ThemeFontModifier(style: style, weight: weight, display: display, mono: mono, digits: digits))
    }
}
