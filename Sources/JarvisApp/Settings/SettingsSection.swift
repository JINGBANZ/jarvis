import AppKit

/// One panel in the unified Settings window. Each section is self-contained: it knows its tab
/// title, builds its own content view, and cleans up when the window closes.
@MainActor
protocol SettingsSection: AnyObject {
    var title: String { get }
    func makeView() -> NSView
    /// Called when the Settings window closes. Default: no-op.
    func windowWillClose()
}

extension SettingsSection {
    func windowWillClose() {}
}
