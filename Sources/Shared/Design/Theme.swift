import SwiftUI

/// The visual language: an industrial control panel rendered as a productivity app.
/// Warm off-white paper, near-black ink, 1px rules, monospace for anything numeric.
/// No glow, no gradients, no shadows beyond a single hairline of separation.
public struct Theme: Sendable, Equatable {

    // MARK: Palette

    public var paper: Color          // window background
    public var panel: Color          // raised container fill
    public var panelAlt: Color       // subtly recessed fill (column wells)
    public var ink: Color            // primary type
    public var inkSecondary: Color   // supporting type
    public var inkTertiary: Color    // micro-labels, disabled
    public var line: Color           // hairline borders
    public var lineStrong: Color     // emphasised rule
    public var signal: Color         // overdue / urgent only
    public var accent: Color         // user-selectable, used sparingly
    public var selectionFill: Color
    public var isDark: Bool

    // MARK: Variants

    public static let light = Theme(
        paper: Color(hex: 0xE9ECE2),
        panel: Color(hex: 0xF1F3EB),
        panelAlt: Color(hex: 0xE3E7DC),
        ink: Color(hex: 0x15170F),
        // Secondary and tertiary both clear WCAG AA on paper, panel and panelAlt;
        // the old tertiary was 2.49:1, which made every micro-label fuzzy.
        inkSecondary: Color(hex: 0x555B4E),
        inkTertiary: Color(hex: 0x5C6255),
        line: Color(hex: 0xA8AE9D),
        lineStrong: Color(hex: 0x7C8271),
        signal: Color(hex: 0xA03B2B),
        accent: Color(hex: 0x15170F),
        selectionFill: Color(hex: 0xD9DED0),
        isDark: false
    )

    public static let dark = Theme(
        paper: Color(hex: 0x14150F),
        panel: Color(hex: 0x1B1D16),
        panelAlt: Color(hex: 0x101109),
        ink: Color(hex: 0xE7EADF),
        inkSecondary: Color(hex: 0x9AA08D),
        inkTertiary: Color(hex: 0x909686),
        line: Color(hex: 0x484D3E),
        lineStrong: Color(hex: 0x646A58),
        signal: Color(hex: 0xD9785F),
        accent: Color(hex: 0xE7EADF),
        selectionFill: Color(hex: 0x2A2D22),
        isDark: true
    )

    public static func resolved(dark: Bool, accent: AccentChoice) -> Theme {
        var t = dark ? Theme.dark : Theme.light
        if let c = accent.color(dark: dark) { t.accent = c }
        return t
    }

    /// Card fill by priority: a quiet temperature ramp from neutral to rust.
    public func priorityFill(_ priority: Priority) -> Color {
        switch priority {
        case .low: return panel
        case .medium: return isDark ? Color(hex: 0x23261A) : Color(hex: 0xE8EAD9)
        case .high: return isDark ? Color(hex: 0x2E2718) : Color(hex: 0xEDDFC0)
        case .urgent: return isDark ? Color(hex: 0x35221D) : Color(hex: 0xEAD0C7)
        }
    }

    // MARK: Metrics

    public enum Radius {
        public static let panel: CGFloat = 16
        public static let card: CGFloat = 10
        public static let control: CGFloat = 8
        public static let pill: CGFloat = 999
    }

    public enum Metric {
        public static let hairline: CGFloat = 1
        public static let gutter: CGFloat = 16
        public static let cardPadding: CGFloat = 11
        public static let columnWidth: CGFloat = 248
        public static let rowHeight: CGFloat = 28
    }

    // MARK: Type

    /// Geometric sans for headings; the system face is the closest available to the reference.
    public static func display(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Monospace for every number, status and piece of metadata.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    public static let microLabel = mono(9.5, weight: .medium)
    public static let meta = mono(10.5)
    public static let body = display(12.5, weight: .regular)
    public static let cardTitle = display(12.5, weight: .medium)
    public static let sectionTitle = display(13, weight: .medium)
    public static let bigValue = mono(30, weight: .light)
}

// MARK: - Accent choice

public enum AccentChoice: String, CaseIterable, Codable, Sendable {
    case mono
    case amber
    case rust
    case moss
    case slate

    public var label: String { rawValue.uppercased() }

    public func color(dark: Bool) -> Color? {
        switch self {
        case .mono: return nil
        case .amber: return Color(hex: dark ? 0xD9A441 : 0xB07B14)
        case .rust: return Color(hex: dark ? 0xD26A54 : 0xA0432B)
        case .moss: return Color(hex: dark ? 0x8FA96B : 0x5C7238)
        case .slate: return Color(hex: dark ? 0x8FA3B8 : 0x46607A)
        }
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.light
}

public extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Color helper

public extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
