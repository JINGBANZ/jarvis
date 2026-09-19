import AppKit

/// Every text color here clears 4.5:1 on `card`, `backgroundCenter`, and `backgroundEdge` in both
/// appearances. Settings keeps `SettingsTheme`.
@MainActor
enum OnboardingTheme {
    static let backgroundCenter = SettingsTheme.dynamic(light: 0xFFFFFF, dark: 0x221B3B)
    static let backgroundEdge = SettingsTheme.dynamic(light: 0xECE8FA, dark: 0x0C0A16)
    static let card = SettingsTheme.dynamic(light: 0xFFFFFF, dark: 0x2A2345)
    static let well = SettingsTheme.dynamic(light: 0xEFE9FF, dark: 0x3A3160)
    static let line = SettingsTheme.dynamic(
        light: 0x7C4DFF, dark: 0xC4AAFF, alpha: (0.24, 0.26), highContrastAlpha: 1)
    static let lineSoft = SettingsTheme.dynamic(
        light: 0x7C4DFF, dark: 0xC4AAFF, alpha: (0.12, 0.12), highContrastAlpha: 0.35)
    static let text = SettingsTheme.dynamic(light: 0x1C1535, dark: 0xF5F2FF)
    static let secondaryText = SettingsTheme.dynamic(light: 0x574C7E, dark: 0xCBC3E6)
    static let tertiaryText = SettingsTheme.dynamic(light: 0x625887, dark: 0xA89FCB)
    static let purple = SettingsTheme.dynamic(light: 0x7C4DFF, dark: 0xBCA2FF)
    static let teal = SettingsTheme.dynamic(light: 0x0E9F87, dark: 0x3FE0C4)
    static let tealText = SettingsTheme.dynamic(light: 0x0A7A67, dark: 0x3FE0C4)
    static let amber = SettingsTheme.dynamic(light: 0x9A5B00, dark: 0xFFBE5C)
    static let link = SettingsTheme.dynamic(light: 0x0062CC, dark: 0x7DBBFF)
    static let ring = SettingsTheme.dynamic(light: 0x0E9F87, dark: 0x3FE0C4, alpha: (0.22, 0.22))
}
