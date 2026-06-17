import AppKit
import JarvisCore

/// Menu-bar status item: start/stop, API-key entry, and a session interjection counter.
/// Exactly two states: ⚪️ stopped and 🟢 running.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let keychain: KeychainSecretStore
    private let counterItem = NSMenuItem(title: "Interjections: 0", action: nil, keyEquivalent: "")
    private let startStopItem = NSMenuItem(title: "Start Jarvis", action: nil, keyEquivalent: "s")
    private let logViewerItem = NSMenuItem(title: "Open Log Viewer", action: nil, keyEquivalent: "l")
    private var interjections = 0
    /// Whether the listen/coach pipeline is currently running.
    private(set) var isRunning = false

    /// Fired when the user asks to start the pipeline. Returns `true` if it actually started
    /// (e.g. a key was available), so the menu can reflect the real state.
    var onStart: (() -> Bool)?
    /// Fired when the user asks to stop the pipeline.
    var onStop: (() -> Void)?
    /// Fired after a new key is saved to the Keychain. The app does *not* auto-start; the user
    /// presses Start when ready.
    var onKeySaved: ((String) -> Void)?
    /// Fired when the user picks "Open Log Viewer" (dev mode only). Opens the session's activity
    /// HTML on demand instead of auto-opening it on launch.
    var onOpenLogViewer: (() -> Void)?

    /// - Parameter showLogViewer: in dev mode, add an "Open Log Viewer" item so the activity HTML
    ///   can be opened on demand rather than auto-opening every launch.
    init(keychain: KeychainSecretStore, showLogViewer: Bool = false) {
        self.keychain = keychain
        super.init()
        let menu = NSMenu()
        startStopItem.target = self
        startStopItem.action = #selector(toggleStartStop)
        menu.addItem(startStopItem)
        let key = NSMenuItem(title: "Set OpenAI API Key…", action: #selector(setKey), keyEquivalent: "k")
        key.target = self
        menu.addItem(key)
        if showLogViewer {
            logViewerItem.target = self
            logViewerItem.action = #selector(openLogViewer)
            menu.addItem(logViewerItem)
        }
        menu.addItem(.separator())
        menu.addItem(counterItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        refreshUI()
    }

    func noteSpoke() {
        interjections += 1
        counterItem.title = "Interjections: \(interjections)"
    }

    /// Reset the per-session interjection count (called on each Start).
    func resetCounter() {
        interjections = 0
        counterItem.title = "Interjections: 0"
    }

    /// The single source of truth for running state. The app calls this for state it drives itself
    /// (a failed/asynchronously-dead Start, a key-save restart, a terminal socket failure), and
    /// `toggleStartStop` routes through it too — so the menu can never disagree with the pipeline.
    func setRunning(_ running: Bool) {
        isRunning = running
        refreshUI()
    }

    @objc private func openLogViewer() { onOpenLogViewer?() }

    @objc private func toggleStartStop() {
        if isRunning {
            onStop?()
            setRunning(false)
        } else {
            setRunning(onStart?() ?? false)
        }
    }

    /// Single source of truth for the status title and the start/stop label.
    private func refreshUI() {
        startStopItem.title = isRunning ? "Stop Jarvis" : "Start Jarvis"
        statusItem.button?.title = isRunning ? "🟢 Jarvis" : "⚪️ Jarvis"
    }

    // MARK: - API key dialog

    /// Shows a box to paste the API key. A menu-bar (accessory) app's default modal windows can't
    /// reliably become the key window, so the paste/typing wouldn't register. The fix: promote the
    /// app to a regular foreground app for the dialog, use a normal titled NSWindow (which *can*
    /// become key), and explicitly focus the field — then drop back to menu-bar-only.
    @objc private func setKey() {
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(previousPolicy) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "OpenAI API Key"
        window.isReleasedWhenClosed = false
        let content = window.contentView!

        let label = NSTextField(labelWithString: "Paste your OpenAI API key. It’s stored in your Keychain.")
        label.frame = NSRect(x: 20, y: 104, width: 380, height: 20)
        content.addSubview(label)

        let field = NSSecureTextField(frame: NSRect(x: 20, y: 64, width: 380, height: 26))
        field.placeholderString = "sk-…"
        content.addSubview(field)

        let save = NSButton(title: "Save", target: self, action: #selector(saveKeyDialog))
        save.frame = NSRect(x: 310, y: 16, width: 92, height: 32)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"            // Return = Save
        content.addSubview(save)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelKeyDialog))
        cancel.frame = NSRect(x: 210, y: 16, width: 92, height: 32)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"      // Esc = Cancel
        content.addSubview(cancel)

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)     // cursor in the field → paste/typing works

        let response = NSApp.runModal(for: window)
        window.orderOut(nil)

        guard response == .OK else { return }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        keychain.setApiKey(token)            // saved locally in the login Keychain
        onKeySaved?(token)                   // stored; user presses Start when ready (no auto-start)
        flashConfirmation()                  // visible acknowledgement that the key registered
    }

    @objc private func saveKeyDialog() { NSApp.stopModal(withCode: .OK) }
    @objc private func cancelKeyDialog() { NSApp.stopModal(withCode: .cancel) }

    /// Briefly show a checkmark in the menu-bar title so the user sees the key save took effect,
    /// then restore the normal ⚪️/🟢 state.
    private func flashConfirmation() {
        statusItem.button?.title = "✓ Key saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshUI() }
    }
}
