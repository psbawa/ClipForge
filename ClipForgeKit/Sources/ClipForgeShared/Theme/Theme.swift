import SwiftUI

// MARK: Tokens

public struct RGB: Hashable, Sendable {
    public var hex: UInt32
    public var alpha: Double = 1
    public init(_ hex: UInt32, _ alpha: Double = 1) { self.hex = hex; self.alpha = alpha }
    var r: Double { Double((hex >> 16) & 0xFF) / 255 }
    var g: Double { Double((hex >> 8) & 0xFF) / 255 }
    var b: Double { Double(hex & 0xFF) / 255 }
    public var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: alpha) }
    /// WCAG relative luminance.
    var luminance: Double {
        func c(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * c(r) + 0.7152 * c(g) + 0.0722 * c(b)
    }
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (a.luminance, b.luminance)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

public enum Feature: String, CaseIterable, Sendable { case highlights, review, story, vlog, stats, voice, publish }

public struct Palette: Sendable {
    public var canvas, surface, raised, text, muted, border, accent, onAccent, success, warning, danger: RGB
    public var feature: [Feature: RGB]
    public var onFeature: RGB                 // text/icon color on top of a feature fill
    public var chart: [RGB]
    public var shadow: RGB
    public var backdrop: [RGB] = []           // gradient / blobs behind everything (Y2K, Glass)
}

public enum ShadowStyle: Sendable { case none, soft, hardOffset(Double), glow }
public enum MotionStyle: Sendable { case none, gentle, bouncy, snappy }
public struct Effects: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let grain = Effects(rawValue: 1), scanlines = Effects(rawValue: 2), glow = Effects(rawValue: 4)
    public static let blobs = Effects(rawValue: 8), sparkles = Effects(rawValue: 16), glass = Effects(rawValue: 32), chrome = Effects(rawValue: 64)
}

public struct Typography: Sendable {
    public enum Face: Sendable { case system(Font.Design), custom(String) }
    public var display: Face, body: Face, mono: Face
    public var displayWeight: Font.Weight = .bold
    public var uppercaseHeadings = false
    public var displayScale = 1.0             // pixel fonts read larger than they are
}

public struct Theme: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var tagline: String
    public var dark: Palette
    public var light: Palette
    public var preferredScheme: ColorScheme?  // what "Theme default" means for mode
    public var type: Typography
    public var radius: Double
    public var border: Double
    public var shadow: ShadowStyle
    public var effects: Effects
    public var motion: MotionStyle
}
