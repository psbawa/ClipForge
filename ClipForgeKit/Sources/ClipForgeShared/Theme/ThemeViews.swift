import CoreGraphics
import SwiftUI

// MARK: Root

/// Applied once at the root of each window: resolves the theme (mode, accent, effects, accessibility, Low Power),
/// injects it, sets the window's light/dark appearance, tint, body font and the backdrop. Switching re-renders instantly.
public struct ThemeRoot: ViewModifier {
    @Bindable var store: ThemeStore
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.colorSchemeContrast) var contrast
    @Environment(\.colorScheme) var scheme     // the system's when nothing is forced

    public func body(content: Content) -> some View {
        let dark = store.forcedDark ?? (scheme == .dark)
        let r = ResolvedTheme.resolve(store.theme, dark: dark, accent: store.accent, level: store.effects, reduceMotion: reduceMotion,
                                      reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased, lowPower: store.lowPower)
        content
            .environment(\.theme, r)
            .preferredColorScheme(store.forcedDark.map { $0 ? .dark : .light })
            .tint(r.color(.accent))
            .themeFont(.body)
            .foregroundStyle(.themeText)
            .background { ThemeBackdrop().environment(\.theme, r).ignoresSafeArea() }
            #if os(macOS)
            .toolbarBackground(r.color(.surface), for: .windowToolbar)
            #else
            .toolbarBackground(r.color(.surface), for: .navigationBar, .tabBar)
            #endif
            .scrollContentBackground(.hidden)      // lists, forms and tables show the theme instead of system fills
            .groupBoxStyle(ThemedGroupBoxStyle())
            .buttonStyle(.themed)
            .animation(r.animation, value: store.themeID)
            .animation(r.animation, value: dark)
    }
}

public extension View {
    /// Sheets are separate windows: they inherit the theme environment but not the root's backdrop.
    func themedSheet() -> some View {
        themeFont(.body).foregroundStyle(.themeText).background { ThemeBackdrop().ignoresSafeArea() }
    }
    func clipForgeTheme(_ store: ThemeStore = .shared) -> some View { modifier(ThemeRoot(store: store)) }
}

// MARK: Backdrop & effects (background only — never drawn over content or video)

struct ThemeBackdrop: View {
    @Environment(\.theme) var t
    var body: some View {
        ZStack {
            t.color(.canvas)
            if t.effects.contains(.blobs), t.p.backdrop.count >= 3 {
                GeometryReader { g in
                    let w = g.size.width, h = g.size.height
                    ZStack {
                        Circle().fill(t.p.backdrop[0].color).frame(width: w * 0.5).position(x: w * 0.2, y: h * 0.2)
                        Circle().fill(t.p.backdrop[1].color).frame(width: w * 0.45).position(x: w * 0.85, y: h * 0.8)
                        Circle().fill(t.p.backdrop[2].color).frame(width: w * 0.35).position(x: w * 0.6, y: h * 0.05)
                    }.blur(radius: 90).opacity(t.effectsOpacity)
                }.drawingGroup()      // rasterized once; static, so scrubbing/playback never re-renders it
            } else if t.effects.contains(.chrome), !t.p.backdrop.isEmpty {
                LinearGradient(colors: t.p.backdrop.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing).opacity(t.effectsOpacity)
            }
            if t.effects.contains(.sparkles) {
                GeometryReader { g in
                    ForEach(0..<9, id: \.self) { i in
                        Image(systemName: "sparkle").font(.system(size: CGFloat(8 + (i * 7) % 14)))
                            .foregroundStyle(t.color(.feature(Feature.allCases[i % 7])).opacity(0.55 * t.effectsOpacity))
                            .position(x: g.size.width * [0.08, 0.31, 0.55, 0.92, 0.18, 0.72, 0.44, 0.86, 0.62][i], y: g.size.height * [0.12, 0.88, 0.07, 0.35, 0.55, 0.93, 0.48, 0.66, 0.24][i])
                    }
                }
            }
            if t.effects.contains(.grain) { Tile.grain.resizable(resizingMode: .tile).opacity(0.5 * t.effectsOpacity).blendMode(t.dark ? .screen : .multiply) }
            if t.effects.contains(.scanlines) { Tile.scanlines(dark: t.dark).resizable(resizingMode: .tile).opacity(t.effectsOpacity) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Pre-rendered tiles (CoreGraphics, so macOS and iOS share them): grain and scanlines cost nothing per frame.
enum Tile {
    static func image(_ w: Int, _ h: Int, draw: (CGContext) -> Void) -> Image {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return Image(decorative: ctx.makeImage()!, scale: 1)
    }
    static let grain: Image = image(192, 192) { ctx in
        var g = SystemRandomNumberGenerator()
        for y in 0..<192 { for x in 0..<192 {
            let v = Double.random(in: 0...1, using: &g)
            ctx.setFillColor(CGColor(gray: v, alpha: Double.random(in: 0...0.11, using: &g)))
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
    }
    static func scanlines(dark: Bool) -> Image {
        image(4, 3) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: dark ? 0.22 : 0.07))
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 1))
        }
    }
}

// MARK: Components

public enum ThemedButtonKind: Sendable { case primary, secondary, destructive }

/// Themed push button: chrome (Y2K), hard offset (Neon/Arcade), square + thick border (Brutalist), soft (others).
public struct ThemedButtonStyle: ButtonStyle {
    var kind: ThemedButtonKind = .secondary
    public init(_ kind: ThemedButtonKind = .secondary) { self.kind = kind }
    public func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, kind: configuration.role == .destructive ? .destructive : kind)
    }

    struct Styled: View {
        let configuration: Configuration; let kind: ThemedButtonKind
        @Environment(\.theme) var t
        @Environment(\.isEnabled) var enabled
        @Environment(\.controlSize) var size
        @State var hover = false
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: t.radius == 0 ? 0 : min(t.radius, 10) + (t.effects.contains(.chrome) ? 8 : 0))
            let fill: Color = kind == .primary ? t.color(.accent) : kind == .destructive ? t.color(.danger) : t.color(.raised)
            let ink: Color = t.effects.contains(.chrome) && kind != .destructive ? RGB(0x1F1B3A).color
                : kind == .primary ? t.color(.onAccent) : kind == .destructive ? (t.dark ? RGB(0x0B0B0F).color : .white) : t.color(.text)
            let offset: Double = { if case .hardOffset(let d) = t.theme.shadow { return configuration.isPressed ? 0 : d / 1.5 }; return 0 }()
            let small = size == .small || size == .mini
            configuration.label
                .themeFont(small ? .caption : .callout, weight: .semibold, display: t.theme.id == "arcade")
                .foregroundStyle(ink)
                .padding(.horizontal, small ? 8 : 12).padding(.vertical, small ? 3 : 6)
                .background {
                    if t.effects.contains(.chrome), kind != .destructive {
                        shape.fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.8), Color(white: 0.95), Color(white: 0.84)], startPoint: .top, endPoint: .bottom))
                            .overlay(shape.fill(LinearGradient(colors: kind == .primary ? [t.color(.feature(.review)).opacity(0.5), t.color(.feature(.story)).opacity(0.5), t.color(.feature(.highlights)).opacity(0.5)] : [.clear], startPoint: .leading, endPoint: .trailing)))
                    } else { shape.fill(fill) }
                }
                .overlay(shape.stroke(t.theme.id == "neon" || t.theme.id == "brutalist" ? t.color(.text) : t.color(.border), lineWidth: t.borderWidth))
                .overlay { if hover && !configuration.isPressed { shape.fill(t.color(.text).opacity(0.06)) } }
                .background { if offset > 0 { shape.fill(Color.black).offset(x: offset, y: offset) } }
                .offset(x: configuration.isPressed ? offset : 0, y: configuration.isPressed ? offset : 0)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(shape)
                .onHover { hover = $0 }
                .animation(t.reduceMotion ? nil : .snappy(duration: 0.12), value: configuration.isPressed)
        }
    }
}

public extension ButtonStyle where Self == ThemedButtonStyle {
    static var themed: ThemedButtonStyle { ThemedButtonStyle(.secondary) }
    static var themedPrimary: ThemedButtonStyle { ThemedButtonStyle(.primary) }
    static var themedDestructive: ThemedButtonStyle { ThemedButtonStyle(.destructive) }
}

/// Card / inspector panel: surface fill, border, theme shadow; Glass uses a real material unless transparency is reduced.
struct ThemedCard: ViewModifier {
    @Environment(\.theme) var t
    var feature: Feature?
    var padding: Double = 12
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.radius)
        let stroke = feature.flatMap { t.theme.id == "neon" ? t.color(.feature($0)) : nil } ?? t.color(.border)
        content.padding(padding)
            .background {
                if t.effects.contains(.glass) && !t.solidSurfaces { shape.fill(.ultraThinMaterial).overlay(shape.fill(t.color(.surface))) }
                else { shape.fill(t.color(.surface)) }
            }
            .overlay(shape.stroke(stroke, lineWidth: t.borderWidth))
            .background { shadow(shape) }
    }
    @ViewBuilder func shadow(_ s: RoundedRectangle) -> some View {
        switch t.theme.shadow {
        case .hardOffset(let d): s.fill(t.dark && t.theme.id == "neon" ? (feature.map { t.color(.feature($0)) } ?? t.color(.accent)) : Color.black).offset(x: d, y: d)
        case .soft: s.fill(t.color(.surface)).shadow(color: t.p.shadow.color, radius: 12, y: 5)
        case .glow: s.fill(t.color(.accent)).blur(radius: 10).opacity(0.35)
        case .none: EmptyView()
        }
    }
}

public extension View {
    func themedCard(_ feature: Feature? = nil, padding: Double = 12) -> some View { modifier(ThemedCard(feature: feature, padding: padding)) }
    /// Lists/Forms/Tables draw their own background; hide it so the theme's surface shows through.
    func themedScrollBackground(_ role: ResolvedTheme.Role? = nil) -> some View {
        modifier(ScrollBackground(role: role))
    }
}

struct ScrollBackground: ViewModifier {
    @Environment(\.theme) var t
    var role: ResolvedTheme.Role?
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden).background { if let role { t.color(role).opacity(t.effects.contains(.glass) && !t.solidSurfaces ? 0.6 : 1) } }
    }
}

public struct ThemedGroupBoxStyle: GroupBoxStyle {
    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            configuration.label.themeFont(.headline, display: true)
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard()
    }
}

/// Sticker / pill / 8-bit badge.
public struct ThemeBadge: View {
    @Environment(\.theme) var t
    let text: String; var feature: Feature?
    public init(_ text: String, feature: Feature? = nil) { self.text = text; self.feature = feature }
    public var body: some View {
        let square = t.radius == 0 || t.theme.id == "arcade"
        let shape = RoundedRectangle(cornerRadius: square ? 0 : 99)
        Text(t.heading(text))
            .themeFont(.caption2, weight: .bold, display: t.theme.id == "arcade", mono: t.theme.id != "arcade")
            .foregroundStyle(feature == nil ? t.color(.onAccent) : t.color(.onFeature))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(shape.fill(feature.map { t.color(.feature($0)) } ?? t.color(.accent)))
            .overlay { if t.theme.id == "neon" || t.theme.id == "brutalist" { shape.stroke(t.color(.text), lineWidth: 1.5) } }
            .background { if case .hardOffset = t.theme.shadow { shape.fill(Color.black).offset(x: 2, y: 2) } }
            .rotationEffect(.degrees(t.theme.id == "neon" ? -3 : 0))
            .fixedSize()
    }
}

/// Dashboard stat tile.
public struct StatCard: View {
    let title: String, value: String, sub: String; var feature: Feature
    public init(_ title: String, _ value: String, _ sub: String = "", feature: Feature = .stats) { self.title = title; self.value = value; self.sub = sub; self.feature = feature }
    @Environment(\.theme) var t
    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t.heading(title)).themeFont(.caption, display: t.theme.id == "arcade").foregroundStyle(.themeMuted)
            Text(value).themeFont(.title2, weight: .bold, display: t.theme.id == "arcade", digits: true).foregroundStyle(.themeText)
            if !sub.isEmpty { Text(sub).themeFont(.caption2).foregroundStyle(.themeMuted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(feature, padding: 10)
    }
}

/// Section heading in the theme's display face.
public struct ThemeHeading: View {
    @Environment(\.theme) var t
    let text: String; var style: Font.TextStyle
    public init(_ text: String, _ style: Font.TextStyle = .headline) { self.text = text; self.style = style }
    public var body: some View { Text(t.heading(text)).themeFont(style, display: true).foregroundStyle(.themeText) }
}

/// Sidebar row with the feature's signature color on its icon.
public struct SidebarRow: View {
    let title: String, icon: String, feature: Feature
    public init(_ title: String, _ icon: String, _ feature: Feature) { self.title = title; self.icon = icon; self.feature = feature }
    public var body: some View {
        Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(.themeInk(feature)) }
    }
}
