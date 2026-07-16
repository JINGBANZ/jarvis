import AppKit

/// One panel in the unified Settings window. Each section is self-contained: it knows its tab
/// title, builds its own content view, reacts to becoming the visible tab, and cleans up when the
/// window closes.
@MainActor
protocol SettingsSection: AnyObject {
    var title: String { get }
    func makeView() -> NSView
    /// This section's tab became the selected one. Default: no-op.
    func didBecomeActive()
    /// This section's tab stopped being selected (another tab chosen, or the window is closing).
    /// Default: no-op.
    func didResignActive()
    /// Called when the Settings window closes. Default: no-op.
    func windowWillClose()
    /// Whether this section's view should stretch to fill the whole tab. Default: false — the
    /// fixed-form panels keep their designed size, pinned to the top of the tab.
    var fillsTab: Bool { get }
}

extension SettingsSection {
    func didBecomeActive() {}
    func didResignActive() {}
    func windowWillClose() {}
    var fillsTab: Bool { false }
}
