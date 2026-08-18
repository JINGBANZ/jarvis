import AppKit

/// Resolves the update item's availability each time the menu opens, because it depends on live
/// session state rather than anything fixed at construction. `MenuBarController` turns off AppKit's
/// automatic item validation to make room for this, so the menu's other items state their own
/// enabled state directly.
extension MenuBarController: NSMenuDelegate {
    /// An update installs by quitting and relaunching Jarvis, and its dialog is not one of the
    /// presentation paths the runtime safety boundary permits during a live session — so the check is
    /// offered only while stopped, and only when Sparkle has no check already in flight.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let updateItem, let updateAvailability else { return }
        updateItem.isEnabled = !isRunning && updateAvailability()
        updateItem.toolTip = isRunning ? "Stop Jarvis to check for updates" : nil
    }
}
