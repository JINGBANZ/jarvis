import AppKit
import JarvisCore

/// Settings panel for what the coach screenshots when `capture_screen` fires. One dropdown covers
/// both decisions: the active window (default) or one "Entire display" entry per connected display,
/// named the way `screencapture -D` counts them (1 = the main display, the one with the menu bar;
/// `NSScreen.screens` puts the main display first in the same order). Persisted through
/// `ScreenCapturePreferences` and read at capture time, so a change applies to the very next
/// screenshot — no restart needed. The display entries refresh when displays are plugged or
/// unplugged while the tab is visible; a stored selection pointing at a now-missing display shows
/// (and captures — see `ScreenCaptureCLI`) the main display without clobbering the stored value,
/// so replugging the monitor restores the choice.
@MainActor
final class DisplaySection: NSObject, SettingsSection {
    let title = "Screen"

    private let preferences: ScreenCapturePreferences
    private var popup: NSPopUpButton?
    private var screenObserver: NSObjectProtocol?

    init(preferences: ScreenCapturePreferences) {
        self.preferences = preferences
    }

    func makeView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 432))

        let label = NSTextField(labelWithString: "Capture Scope")
        label.frame = NSRect(x: 24, y: 372, width: 200, height: 20)
        view.addSubview(label)

        let popup = NSPopUpButton(frame: NSRect(x: 24, y: 340, width: 380, height: 26))
        popup.target = self
        popup.action = #selector(scopeChanged)
        popup.setAccessibilityLabel("Capture scope")
        view.addSubview(popup)
        self.popup = popup
        reloadItems()

        let note = NSTextField(labelWithString: "Active window captures the window you're clicking and typing in, on any display.")
        note.frame = NSRect(x: 24, y: 308, width: 512, height: 20)
        note.textColor = .secondaryLabelColor
        view.addSubview(note)
        let note2 = NSTextField(labelWithString: "When no window is capturable, or a chosen display is disconnected, the main display is captured.")
        note2.frame = NSRect(x: 24, y: 288, width: 512, height: 20)
        note2.textColor = .secondaryLabelColor
        view.addSubview(note2)

        return view
    }

    func didBecomeActive() {
        reloadItems() // catch a plug/unplug that happened while another tab was selected
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadItems() }
        }
    }

    func didResignActive() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    /// Row 0 is the active-window scope; on rows 1…n the row number IS the display's
    /// `screencapture -D` index.
    private func reloadItems() {
        guard let popup else { return }
        popup.removeAllItems()
        popup.addItem(withTitle: "Active window (recommended)")
        popup.addItems(withTitles: NSScreen.displayTitles.map { "Entire display — \($0)" })
        switch preferences.scope {
        case .activeWindow:
            popup.selectItem(at: 0)
        case .entireDisplay:
            // Show the stored display if it's still connected, else the main display — without
            // clobbering the stored value, so replugging the monitor restores the choice.
            // (Screens can be briefly empty mid-reconfigure, leaving only row 0.)
            let stored = preferences.displayIndex
            popup.selectItem(at: stored < popup.numberOfItems ? stored : min(1, popup.numberOfItems - 1))
        }
    }

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard row >= 0 else { return }
        if row == 0 {
            preferences.scope = .activeWindow
        } else {
            preferences.scope = .entireDisplay
            preferences.displayIndex = row
        }
    }
}
