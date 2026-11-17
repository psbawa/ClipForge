import SwiftUI

public enum Themes {
    public static let all: [Theme] = [neon, y2k, brutalist, arcade, glass, minimal]

    public static let neon = Theme(
        id: "neon", name: "Neon Darkroom", tagline: "Near-black, electric color, sticker badges",
        dark: Palette(canvas: RGB(0x0B0B0F), surface: RGB(0x15151C), raised: RGB(0x1E1E28), text: RGB(0xF4F4F6), muted: RGB(0xA6A6B8),
                      border: RGB(0x34343F), accent: RGB(0xC6FF3D), onAccent: RGB(0x0B0B0F), success: RGB(0x3DFF9E), warning: RGB(0xFFB23D), danger: RGB(0xFF5C6C),
                      feature: [.highlights: RGB(0xC6FF3D), .review: RGB(0xFF3DCB), .story: RGB(0xA58BFF), .vlog: RGB(0xFF8A3D),
                                .stats: RGB(0x3DE0FF), .voice: RGB(0xFFE14D), .publish: RGB(0x3DFF9E)],
                      onFeature: RGB(0x0B0B0F), chart: [RGB(0xC6FF3D), RGB(0xFF3DCB), RGB(0x3DE0FF), RGB(0xFF8A3D), RGB(0xA58BFF)], shadow: RGB(0x000000)),
        light: Palette(canvas: RGB(0xF4F3EE), surface: RGB(0xFFFFFF), raised: RGB(0xECEBE4), text: RGB(0x0B0B0F), muted: RGB(0x55556A),
                       border: RGB(0x0B0B0F), accent: RGB(0xC6FF3D), onAccent: RGB(0x0B0B0F), success: RGB(0x0E7A45), warning: RGB(0x9A5B00), danger: RGB(0xC4152A),
                       feature: [.highlights: RGB(0xC6FF3D), .review: RGB(0xFF3DCB), .story: RGB(0xA58BFF), .vlog: RGB(0xFF8A3D),
                                 .stats: RGB(0x3DE0FF), .voice: RGB(0xFFE14D), .publish: RGB(0x3DFF9E)],
                       onFeature: RGB(0x0B0B0F), chart: [RGB(0x5E8A00), RGB(0xC8189E), RGB(0x0089A8), RGB(0xC85A10), RGB(0x6B4FD8)], shadow: RGB(0x0B0B0F)),
        preferredScheme: .dark,
        type: Typography(display: .system(.default), body: .system(.default), mono: .system(.monospaced), displayWeight: .black, uppercaseHeadings: true),
        radius: 10, border: 2, shadow: .hardOffset(4), effects: [.grain, .glow], motion: .snappy)

    public static let y2k = Theme(
        id: "y2k", name: "Y2K Chrome", tagline: "Holographic gradients, chrome buttons, sparkles",
        dark: Palette(canvas: RGB(0x15122B), surface: RGB(0x221F3D), raised: RGB(0x2D2950), text: RGB(0xF4F2FF), muted: RGB(0xBDB8DE),
                      border: RGB(0x6D66A8), accent: RGB(0xB9A6FF), onAccent: RGB(0x15122B), success: RGB(0x7DF5C8), warning: RGB(0xFFD08A), danger: RGB(0xFF8FA8),
                      feature: [.highlights: RGB(0xB9A6FF), .review: RGB(0xFFA6E1), .story: RGB(0x9EE7FF), .vlog: RGB(0xFFD1A6),
                                .stats: RGB(0xA6FFE3), .voice: RGB(0xFFF3A6), .publish: RGB(0xC9FFA6)],
                      onFeature: RGB(0x15122B), chart: [RGB(0xB9A6FF), RGB(0xFFA6E1), RGB(0x9EE7FF), RGB(0xFFD1A6), RGB(0xA6FFE3)], shadow: RGB(0x000000),
                      backdrop: [RGB(0x2A1F5C), RGB(0x16324A), RGB(0x4A1F45)]),
        light: Palette(canvas: RGB(0xF1EEFF), surface: RGB(0xFFFFFF, 0.82), raised: RGB(0xF7F5FF), text: RGB(0x1F1B3A), muted: RGB(0x575272),
                       border: RGB(0xC9C4E8), accent: RGB(0x6B4DFF), onAccent: RGB(0xFFFFFF), success: RGB(0x0F7A55), warning: RGB(0x8F5600), danger: RGB(0xC0204A),
                       feature: [.highlights: RGB(0xC9BCFF), .review: RGB(0xFFC2EA), .story: RGB(0xB8EEFF), .vlog: RGB(0xFFDDBD),
                                 .stats: RGB(0xBDFFEA), .voice: RGB(0xFFF6BD), .publish: RGB(0xD9FFBD)],
                       onFeature: RGB(0x1F1B3A), chart: [RGB(0x6B4DFF), RGB(0xD6339B), RGB(0x1B8FB8), RGB(0xC66A1E), RGB(0x1E9C74)], shadow: RGB(0x6B4DFF, 0.25),
                       backdrop: [RGB(0xE6DEFF), RGB(0xD9FBF1), RGB(0xFFE0F2), RGB(0xE9EEF7)]),
        preferredScheme: .light,
        type: Typography(display: .system(.rounded), body: .system(.rounded), mono: .system(.monospaced), displayWeight: .heavy),
        radius: 20, border: 1, shadow: .soft, effects: [.chrome, .sparkles], motion: .bouncy)

    public static let brutalist = Theme(
        id: "brutalist", name: "Brutalist", tagline: "Black, white, one loud orange. Square and honest.",
        dark: Palette(canvas: RGB(0x000000), surface: RGB(0x000000), raised: RGB(0x111111), text: RGB(0xFFFFFF), muted: RGB(0xBDBDBD),
                      border: RGB(0xFFFFFF), accent: RGB(0xFF5F00), onAccent: RGB(0x000000), success: RGB(0xFFFFFF), warning: RGB(0xFF5F00), danger: RGB(0xFF5F00),
                      feature: Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0, RGB(0xFFFFFF)) }),
                      onFeature: RGB(0x000000), chart: [RGB(0xFFFFFF), RGB(0xFF5F00), RGB(0x8C8C8C)], shadow: RGB(0x000000)),
        light: Palette(canvas: RGB(0xFFFFFF), surface: RGB(0xFFFFFF), raised: RGB(0xF0F0F0), text: RGB(0x000000), muted: RGB(0x3D3D3D),
                       border: RGB(0x000000), accent: RGB(0xFF5F00), onAccent: RGB(0x000000), success: RGB(0x000000), warning: RGB(0x000000), danger: RGB(0x000000),
                       feature: Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0, RGB(0x000000)) }),
                       onFeature: RGB(0xFFFFFF), chart: [RGB(0x000000), RGB(0xFF5F00), RGB(0x8C8C8C)], shadow: RGB(0x000000)),
        preferredScheme: .light,
        type: Typography(display: .custom("Space Grotesk"), body: .custom("Space Grotesk"), mono: .custom("Space Mono"), displayWeight: .bold, uppercaseHeadings: true),
        radius: 0, border: 3, shadow: .none, effects: [], motion: .none)

    public static let arcade = Theme(
        id: "arcade", name: "Retro Arcade", tagline: "CRT blue, pixel headings, scanlines",
        dark: Palette(canvas: RGB(0x0A1440), surface: RGB(0x101D57), raised: RGB(0x18266C), text: RGB(0xEAF1FF), muted: RGB(0xA9B8E8),
                      border: RGB(0x3346A8), accent: RGB(0xFFE600), onAccent: RGB(0x0A1440), success: RGB(0x39FF14), warning: RGB(0xFF9F1C), danger: RGB(0xFF5277),
                      feature: [.highlights: RGB(0xFFE600), .review: RGB(0xFF4FD8), .story: RGB(0x00F0FF), .vlog: RGB(0xFF9F1C),
                                .stats: RGB(0x39FF14), .voice: RGB(0xFF7AF0), .publish: RGB(0x7CFFCB)],
                      onFeature: RGB(0x0A1440), chart: [RGB(0xFFE600), RGB(0xFF4FD8), RGB(0x00F0FF), RGB(0x39FF14), RGB(0xFF9F1C)], shadow: RGB(0x000000)),
        light: Palette(canvas: RGB(0xE7ECFF), surface: RGB(0xFFFFFF), raised: RGB(0xD9E0FF), text: RGB(0x0A1440), muted: RGB(0x3D4A80),
                       border: RGB(0x0A1440), accent: RGB(0x2B3FD6), onAccent: RGB(0xFFFFFF), success: RGB(0x167A00), warning: RGB(0x9A4F00), danger: RGB(0xC2124A),
                       feature: [.highlights: RGB(0xFFE600), .review: RGB(0xFF4FD8), .story: RGB(0x00F0FF), .vlog: RGB(0xFF9F1C),
                                 .stats: RGB(0x39FF14), .voice: RGB(0xFF7AF0), .publish: RGB(0x7CFFCB)],
                       onFeature: RGB(0x0A1440), chart: [RGB(0x2B3FD6), RGB(0xC2189E), RGB(0x0089A8), RGB(0x167A00), RGB(0xC85A10)], shadow: RGB(0x0A1440)),
        preferredScheme: .dark,
        type: Typography(display: .custom("Press Start 2P"), body: .system(.default), mono: .system(.monospaced), displayWeight: .regular, uppercaseHeadings: true, displayScale: 0.72),
        radius: 2, border: 2, shadow: .hardOffset(3), effects: [.scanlines, .glow], motion: .snappy)

    public static let glass = Theme(
        id: "glass", name: "Glassmorphism", tagline: "Color blobs behind frosted panels",
        dark: Palette(canvas: RGB(0x0E0B1F), surface: RGB(0x1B1838, 0.62), raised: RGB(0x2A2650, 0.55), text: RGB(0xFFFFFF), muted: RGB(0xD2CFEA),
                      border: RGB(0xFFFFFF, 0.22), accent: RGB(0x8FD3FF), onAccent: RGB(0x0E0B1F), success: RGB(0x7DFFB8), warning: RGB(0xFFD27A), danger: RGB(0xFF8A9A),
                      feature: [.highlights: RGB(0x8FD3FF), .review: RGB(0xFF9AD5), .story: RGB(0xC2A8FF), .vlog: RGB(0xFFC28F),
                                .stats: RGB(0x8FFFE0), .voice: RGB(0xFFF08F), .publish: RGB(0xA8FF9A)],
                      onFeature: RGB(0x0E0B1F), chart: [RGB(0x8FD3FF), RGB(0xFF9AD5), RGB(0xC2A8FF), RGB(0x8FFFE0), RGB(0xFFC28F)], shadow: RGB(0x000000, 0.35),
                      backdrop: [RGB(0x5A1FC0), RGB(0xA81F62), RGB(0x1A7FA6)]),
        light: Palette(canvas: RGB(0xEEF0FF), surface: RGB(0xFFFFFF, 0.6), raised: RGB(0xFFFFFF, 0.75), text: RGB(0x14122A), muted: RGB(0x45425E),
                       border: RGB(0xFFFFFF, 0.7), accent: RGB(0x3B5BDB), onAccent: RGB(0xFFFFFF), success: RGB(0x0F7A4A), warning: RGB(0x8A5200), danger: RGB(0xB8233F),
                       feature: [.highlights: RGB(0xA9DBFF), .review: RGB(0xFFB8E0), .story: RGB(0xD4C2FF), .vlog: RGB(0xFFD4B0),
                                 .stats: RGB(0xB0FFEA), .voice: RGB(0xFFF5B0), .publish: RGB(0xC6FFB8)],
                       onFeature: RGB(0x14122A), chart: [RGB(0x3B5BDB), RGB(0xC2257A), RGB(0x7048E8), RGB(0x0C8599), RGB(0xD9480F)], shadow: RGB(0x3B3B6B, 0.18),
                       backdrop: [RGB(0xB197FC), RGB(0xFCC2D7), RGB(0x99E9F2)]),
        preferredScheme: nil,
        type: Typography(display: .system(.default), body: .system(.default), mono: .system(.monospaced), displayWeight: .semibold),
        radius: 16, border: 1, shadow: .soft, effects: [.blobs, .glass], motion: .gentle)

    public static let minimal = Theme(
        id: "minimal", name: "Minimal / Focus", tagline: "Neutral, system font, nothing in the way",
        dark: Palette(canvas: RGB(0x1E1E1E), surface: RGB(0x262626), raised: RGB(0x2F2F2F), text: RGB(0xF2F2F2), muted: RGB(0xA8A8A8),
                      border: RGB(0x3A3A3A), accent: RGB(0x4C9AFF), onAccent: RGB(0x0B1A2E), success: RGB(0x5CCB7A), warning: RGB(0xE5B85C), danger: RGB(0xFF6B6B),
                      feature: Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0, RGB(0x4C9AFF)) }),
                      onFeature: RGB(0x0B1A2E), chart: [RGB(0x4C9AFF), RGB(0x8E8E93), RGB(0x5CCB7A), RGB(0xE5B85C)], shadow: RGB(0x000000, 0.25)),
        light: Palette(canvas: RGB(0xF5F5F7), surface: RGB(0xFFFFFF), raised: RGB(0xEDEDF0), text: RGB(0x1D1D1F), muted: RGB(0x5F5F66),
                       border: RGB(0xDCDCE0), accent: RGB(0x0A64D6), onAccent: RGB(0xFFFFFF), success: RGB(0x1E7D3A), warning: RGB(0x8A5A00), danger: RGB(0xC62828),
                       feature: Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0, RGB(0x0A64D6)) }),
                       onFeature: RGB(0xFFFFFF), chart: [RGB(0x0A64D6), RGB(0x6E6E73), RGB(0x1E7D3A), RGB(0xB07400)], shadow: RGB(0x000000, 0.08)),
        preferredScheme: nil,
        type: Typography(display: .system(.default), body: .system(.default), mono: .system(.monospaced), displayWeight: .semibold),
        radius: 8, border: 1, shadow: .none, effects: [], motion: .none)
}
