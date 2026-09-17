import AppKit

/// One page in the Settings window. A section knows its destination, builds its page, reacts to
/// becoming the visible page, and cleans up when the window closes. The hub is not a section.
@MainActor
protocol SettingsSection: AnyObject {
    var destination: SettingsDestination { get }
    func makePage() -> SettingsPageView
    /// This page became the visible one. Default: no-op.
    func didBecomeActive()
    /// Another page was chosen, or the window is closing. Default: no-op.
    func didResignActive()
    /// The Settings window is closing. Default: no-op.
    func windowWillClose()
}

extension SettingsSection {
    func didBecomeActive() {}
    func didResignActive() {}
    func windowWillClose() {}
}
