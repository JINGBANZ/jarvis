import AppKit

/// Jarvis's Settings palette: purple for structure, teal for what is on or selected, amber for what
/// needs the user. Every color resolves per appearance, high contrast included, so a view that draws
/// with these picks up light and dark mode without observing it.
@MainActor
enum SettingsTheme {
    static let purple = dynamic(light: 0x7C4DFF, dark: 0xB18CFF)
    static let teal = dynamic(light: 0x0E9F87, dark: 0x36E2C5)
    static let amber = dynamic(light: 0xB86E00, dark: 0xFFB547)
    static let text = dynamic(light: 0x1C1535, dark: 0xF1EAFF)
    static let mutedText = dynamic(light: 0x6B5F95, dark: 0xA594CC)
    static let dimText = dynamic(light: 0xA39AC4, dark: 0x6F6396)
    static let cardFill = dynamic(light: 0xFFFFFF, dark: 0x1A1433)
    static let fieldFill = dynamic(light: 0xF7F5FF, dark: 0x120D26)
    static let iconWell = dynamic(light: 0xEFE9FF, dark: 0x2E2260)
    static let line = dynamic(light: 0x7C4DFF, dark: 0xB18CFF, alpha: (0.26, 0.35), highContrastAlpha: 1)
    static let lineSoft = dynamic(
        light: 0x7C4DFF, dark: 0xB18CFF, alpha: (0.10, 0.12), highContrastAlpha: 0.35)
    static let backgroundCenter = dynamic(light: 0xFFFFFF, dark: 0x2A1B52)
    static let backgroundEdge = dynamic(light: 0xEBE6FB, dark: 0x0E0A1F)
    static let shell = dynamic(light: 0xFBFAFF, dark: 0x1A1433)
    static let visor = dynamic(light: 0x1A1433, dark: 0x0A0716)
    static let dome = dynamic(light: 0x7C4DFF, dark: 0xB18CFF, alpha: (0.09, 0.14))
    static let circuit = dynamic(light: 0x7C4DFF, dark: 0xD9C6FF)
    static let highlightFill = dynamic(light: 0x0E9F87, dark: 0x36E2C5, alpha: (0.18, 0.16))
    static let glow = dynamic(light: 0x0E9F87, dark: 0x36E2C5, alpha: (0.75, 0.9))
    static let slotGlow = dynamic(light: 0x0E9F87, dark: 0x36E2C5, alpha: (0.35, 0.55))
    static let calloutFill = dynamic(light: 0x0E9F87, dark: 0x36E2C5, alpha: (0.07, 0.06))
    static let noticeFill = dynamic(light: 0xFFAA28, dark: 0xFFB547, alpha: (0.12, 0.08))
    /// The eyes glow the same teal in both modes; the visor behind them stays dark.
    static let eyeGlow = rgb(0x36E2C5)
    static let eyeOff = rgb(0x4A3D80)

    /// The provider closure is `@Sendable` and calls only a `nonisolated` helper, because AppKit may
    /// resolve a dynamic color outside the main actor.
    private static func dynamic(
        light: UInt32,
        dark: UInt32,
        alpha: (light: CGFloat, dark: CGFloat) = (1, 1),
        highContrastAlpha: CGFloat? = nil
    ) -> NSColor {
        NSColor(name: nil) { @Sendable appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let isHighContrast = match == .accessibilityHighContrastAqua
                || match == .accessibilityHighContrastDarkAqua
            let base = isDark ? alpha.dark : alpha.light
            return rgb(isDark ? dark : light, alpha: isHighContrast ? (highContrastAlpha ?? base) : base)
        }
    }

    nonisolated private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}
