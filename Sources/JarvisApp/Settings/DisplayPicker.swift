import AppKit
import JarvisCore

/// The start-time display prompt: when more than one display is connected, Start first asks which
/// screen the coach should watch (an alert with a dropdown, pre-selected to the persisted choice)
/// instead of silently reusing the last selection. With a single display there is nothing to choose,
/// so no prompt. Writes the choice through `ScreenCapturePreferences` — the same store Settings →
/// Screen edits, so the prompt and the Settings tab stay one setting.
@MainActor
enum DisplayPicker {
    /// Returns true to proceed with Start (choice saved), false if the user cancelled.
    static func confirmSelection(preferences: ScreenCapturePreferences) -> Bool {
        let titles = NSScreen.displayTitles
        guard titles.count > 1 else { return true }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        popup.addItems(withTitles: titles)
        popup.setAccessibilityLabel("Capture display")
        let stored = preferences.displayIndex
        popup.selectItem(at: stored <= titles.count ? stored - 1 : 0)

        NSApp.activate(ignoringOtherApps: true) // same surfacing pattern as ErrorReporter's alerts
        let alert = NSAlert()
        alert.messageText = "Which screen should Jarvis watch?"
        alert.informativeText = "Coaching screenshots are taken from this display. Change it anytime in Settings → Screen."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Start")   // first button = default (Return)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        preferences.displayIndex = popup.indexOfSelectedItem + 1
        return true
    }
}
