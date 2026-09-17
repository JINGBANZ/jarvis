import AppKit

extension MenuBarController: NSMenuDelegate {
    /// Only while stopped: the update dialog is not an allowed presentation path mid-session.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let updateItem, let updateAvailability else { return }
        updateItem.isEnabled = !isRunning && updateAvailability()
        updateItem.toolTip = isRunning ? "Stop Jarvis to check for updates" : nil
    }
}
