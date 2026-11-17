import AppKit
import Foundation
import Testing
@testable import ClipForgeKit
@testable import ClipForgeShared

/// Every text/background pair the components use passes WCAG AA (4.5:1 text, 3:1 icons), in every theme, light and dark.
/// A new theme that fails cannot ship unnoticed.
@Test(arguments: Themes.all.map(\.id))
func themeMeetsWCAGAA(_ id: String) {
    let th = Themes.all.first { $0.id == id }!
    for (mode, p) in [("dark", th.dark), ("light", th.light)] {
        func flat(_ c: RGB, on bg: RGB) -> RGB {     // translucent colors composited over what's behind them
            guard c.alpha < 1 else { return c }
            func mix(_ a: Double, _ b: Double) -> UInt32 { UInt32(((a * c.alpha + b * (1 - c.alpha)) * 255).rounded()) }
            return RGB((mix(c.r, bg.r) << 16) | (mix(c.g, bg.g) << 8) | mix(c.b, bg.b))
        }
        let canvas = p.backdrop.isEmpty ? p.canvas : p.backdrop.reduce(p.canvas) { flat(RGB($1.hex, 0.5), on: $0) }
        let surface = flat(p.surface, on: canvas), raised = flat(p.raised, on: surface)
        var pairs: [(String, RGB, RGB, Double)] = [
            ("text/canvas", p.text, canvas, 4.5), ("text/surface", p.text, surface, 4.5), ("text/raised", p.text, raised, 4.5),
            ("muted/canvas", p.muted, canvas, 4.5), ("muted/surface", p.muted, surface, 4.5), ("muted/raised", p.muted, raised, 4.5),
            ("onAccent/accent", p.onAccent, p.accent, 4.5), ("danger/surface", p.danger, surface, 4.5),
            ("warning/surface", p.warning, surface, 4.5), ("success/surface", p.success, surface, 4.5),
        ]
        for (f, c) in p.feature {
            pairs.append(("onFeature/\(f)", p.onFeature, c, 4.5))
            if mode == "dark" { pairs.append(("icon \(f)/surface", c, surface, 3)) }   // light modes draw icons in muted ink
        }
        if th.effects.contains(.chrome) { pairs.append(("chrome ink", RGB(0x1F1B3A), RGB(0xC7C7C7), 4.5)) }
        for (name, a, b, min) in pairs {
            #expect(RGB.contrast(a, b) >= min, "\(id) \(mode) \(name): \(RGB.contrast(a, b))")
        }
    }
}

@Test func resolutionFollowsSystemSettings() {
    let glass = Themes.glass
    let normal = ResolvedTheme.resolve(glass, dark: true, accent: nil, level: .full, reduceMotion: false, reduceTransparency: false, increaseContrast: false, lowPower: false)
    #expect(normal.effects.contains(.glass) && normal.effects.contains(.blobs) && !normal.solidSurfaces && normal.animation != nil)
    let rt = ResolvedTheme.resolve(glass, dark: true, accent: nil, level: .full, reduceMotion: false, reduceTransparency: true, increaseContrast: false, lowPower: false)
    #expect(!rt.effects.contains(.glass) && !rt.effects.contains(.blobs) && rt.solidSurfaces && rt.p.surface.alpha == 1)
    let rm = ResolvedTheme.resolve(Themes.y2k, dark: false, accent: nil, level: .full, reduceMotion: true, reduceTransparency: false, increaseContrast: false, lowPower: false)
    #expect(rm.animation == nil)
    let ic = ResolvedTheme.resolve(Themes.neon, dark: true, accent: nil, level: .full, reduceMotion: false, reduceTransparency: false, increaseContrast: true, lowPower: false)
    #expect(ic.p.muted == ic.p.text && ic.borderWidth == Themes.neon.border + 1)
    let lp = ResolvedTheme.resolve(Themes.neon, dark: true, accent: nil, level: .full, reduceMotion: false, reduceTransparency: false, increaseContrast: false, lowPower: true)
    #expect(!lp.effects.contains(.grain) && !lp.effects.contains(.glow))
    let off = ResolvedTheme.resolve(Themes.arcade, dark: true, accent: nil, level: .off, reduceMotion: false, reduceTransparency: false, increaseContrast: false, lowPower: false)
    #expect(off.effects.isEmpty)
}

@Test func accentOverrideKeepsReadableInk() {
    for hex: UInt32 in [0xFFE600, 0x1A237E, 0xFF3DCB, 0x00A86B, 0x777777] {
        let r = ResolvedTheme.resolve(Themes.minimal, dark: false, accent: hex, level: .full, reduceMotion: false, reduceTransparency: false, increaseContrast: false, lowPower: false)
        #expect(r.p.accent.hex == hex)
        #expect(RGB.contrast(r.p.onAccent, r.p.accent) >= 4.0, "accent \(String(hex, radix: 16))")
    }
}

@Test func everyThemeIsCompleteAndFontsAreBundled() {
    #expect(Set(Themes.all.map(\.id)).count == Themes.all.count)
    for th in Themes.all { for p in [th.dark, th.light] { #expect(Set(p.feature.keys) == Set(Feature.allCases) && !p.chart.isEmpty) } }
    let fonts = ThemeStore.bundled("ttf")
    #expect(fonts.count == 3)
    #expect(ThemeStore.bundled("txt").filter { $0.lastPathComponent.hasPrefix("OFL") }.count == 3)
}

/// Regression: the fonts must actually register (a wrong bundle path silently fell back to the system font).
@MainActor @Test func bundledFontsRegister() {
    ThemeStore.registerFonts()
    for family in ["Press Start 2P", "Space Grotesk", "Space Mono"] {
        #expect(NSFontManager.shared.availableMembers(ofFontFamily: family)?.isEmpty == false, "\(family) not registered")
    }
}
