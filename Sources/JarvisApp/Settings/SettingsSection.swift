import AppKit

@MainActor
protocol SettingsSection: AnyObject {
    var title: String { get }
    func makeView() -> NSView
    func didBecomeActive()
    /// Also called when the window closes, before `windowWillClose()`.
    func didResignActive()
    func windowWillClose()
    var fillsTab: Bool { get }
}

extension SettingsSection {
    func didBecomeActive() {}
    func didResignActive() {}
    func windowWillClose() {}
    var fillsTab: Bool { false }
}
