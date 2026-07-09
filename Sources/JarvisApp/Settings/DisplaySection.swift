import AppKit
import JarvisCore

/// Settings panel for what the coach screenshots when `capture_screen` fires. Two dropdowns:
/// the capture scope (the active window — default — or an entire display), and which display
/// entire-display mode and fallback captures use, numbered the way `screencapture -D` counts them
/// (1 = the main display, the one with the menu bar; `NSScreen.screens` puts the main display
/// first in the same order). Persisted through `ScreenCapturePreferences` and read at capture
/// time, so a change applies to the very next screenshot — no restart needed. The display list
/// refreshes when displays are plugged or unplugged while the tab is visible; a stored selection
/// pointing at a now-missing display falls back to the main display at capture (see
/// `ScreenCaptureCLI`).
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

        let scopeLabel = NSTextField(labelWithString: "Capture Scope")
        scopeLabel.frame = NSRect(x: 24, y: 372, width: 200, height: 20)
        view.addSubview(scopeLabel)

        let scopePopup = NSPopUpButton(frame: NSRect(x: 24, y: 340, width: 320, height: 26))
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)
        scopePopup.setAccessibilityLabel("Capture scope")
        scopePopup.addItems(withTitles: ScreenCaptureScope.allCases.map(\.title))
        scopePopup.selectItem(at: ScreenCaptureScope.allCases.firstIndex(of: preferences.scope) ?? 0)
        view.addSubview(scopePopup)

        let scopeNote = NSTextField(labelWithString: "Active window captures the window you're clicking and typing in, on any display.")
        scopeNote.frame = NSRect(x: 24, y: 308, width: 512, height: 20)
        scopeNote.textColor = .secondaryLabelColor
        view.addSubview(scopeNote)

        let label = NSTextField(labelWithString: "Capture Display")
        label.frame = NSRect(x: 24, y: 262, width: 200, height: 20)
        view.addSubview(label)

        let popup = NSPopUpButton(frame: NSRect(x: 24, y: 230, width: 320, height: 26))
        popup.target = self
        popup.action = #selector(displayChanged)
        popup.setAccessibilityLabel("Capture display")
        view.addSubview(popup)
        self.popup = popup
        reloadDisplays()

        let note = NSTextField(labelWithString: "Used by Entire display mode, and as the fallback when no window is capturable.")
        note.frame = NSRect(x: 24, y: 198, width: 512, height: 20)
        note.textColor = .secondaryLabelColor
        view.addSubview(note)
        let note2 = NSTextField(labelWithString: "If the selected display is disconnected, the main display is captured instead.")
        note2.frame = NSRect(x: 24, y: 178, width: 512, height: 20)
        note2.textColor = .secondaryLabelColor
        view.addSubview(note2)

        return view
    }

    func didBecomeActive() {
        reloadDisplays() // catch a plug/unplug that happened while another tab was selected
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadDisplays() }
        }
    }

    func didResignActive() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func reloadDisplays() {
        guard let popup else { return }
        popup.removeAllItems()
        popup.addItems(withTitles: NSScreen.displayTitles)
        guard popup.numberOfItems > 0 else { return } // screens can be briefly empty mid-reconfigure
        // Show the stored selection if that display is still connected, else the main display —
        // without clobbering the stored value, so replugging the monitor restores the choice.
        let stored = preferences.displayIndex
        popup.selectItem(at: stored <= popup.numberOfItems ? stored - 1 : 0)
    }

    @objc private func displayChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard row >= 0 else { return }
        preferences.displayIndex = row + 1
    }

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard row >= 0, row < ScreenCaptureScope.allCases.count else { return }
        preferences.scope = ScreenCaptureScope.allCases[row]
    }
}
