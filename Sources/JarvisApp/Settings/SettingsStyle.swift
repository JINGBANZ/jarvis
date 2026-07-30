import AppKit

/// Shared visual tokens for every Settings section.
///
/// Keeping these values in one place prevents the tabs from drifting back into separate spacing,
/// typography, and control-alignment systems as their content evolves independently.
@MainActor
enum SettingsStyle {
    static let pageHorizontalInset: CGFloat = 24
    static let pageTopInset: CGFloat = 20
    static let pageBottomInset: CGFloat = 24
    static let pageHeaderHeight: CGFloat = 48
    static let pageHeaderSpacing: CGFloat = 16

    static let sectionSpacing: CGFloat = 14
    static let cardCornerRadius: CGFloat = 12
    static let cardHeaderHeight: CGFloat = 42
    static let rowHeight: CGFloat = 56
    static let rowHorizontalInset: CGFloat = 16
    static let controlWidth: CGFloat = 220

    static func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }
}
