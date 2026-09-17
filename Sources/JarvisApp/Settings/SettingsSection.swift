import AppKit

@MainActor
protocol SettingsSection: AnyObject {
    var destination: SettingsDestination { get }
    func makePage() -> SettingsPageView
    func didBecomeActive()
    /// Also called when the window closes, before `windowWillClose()`.
    func didResignActive()
    func windowWillClose()
}

extension SettingsSection {
    func didBecomeActive() {}
    func didResignActive() {}
    func windowWillClose() {}
}
