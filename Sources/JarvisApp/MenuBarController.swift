import AppKit
import JarvisCore

/// Menu-bar status item: on/off (mute), API-key entry, and a session interjection counter.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let guardrails: Guardrails
    private let keychain: KeychainSecretStore
    private let counterItem = NSMenuItem(title: "Interjections: 0", action: nil, keyEquivalent: "")
    private var interjections = 0

    var onMuteChanged: ((Bool) -> Void)?
    /// Fired after a new key is saved to the Keychain, so the app can start coaching immediately.
    var onKeySaved: ((String) -> Void)?

    init(guardrails: Guardrails, keychain: KeychainSecretStore) {
        self.guardrails = guardrails
        self.keychain = keychain
        super.init()
        statusItem.button?.title = "🟢 Jarvis"
        let menu = NSMenu()
        let mute = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "m")
        mute.target = self
        menu.addItem(mute)
        let key = NSMenuItem(title: "Set OpenAI API Key…", action: #selector(setKey), keyEquivalent: "k")
        key.target = self
        menu.addItem(key)
        menu.addItem(.separator())
        menu.addItem(counterItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func noteSpoke() {
        interjections += 1
        counterItem.title = "Interjections: \(interjections)"
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        let nowMuted = !guardrails.isMuted
        guardrails.setMuted(nowMuted)
        sender.state = nowMuted ? .on : .off
        statusItem.button?.title = nowMuted ? "🔇 Jarvis" : "🟢 Jarvis"
        onMuteChanged?(nowMuted)
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
        statusItem.button?.title = "🟢 Jarvis"
        onKeySaved?(token)                   // start coaching now — no relaunch needed
    }

    @objc private func saveKeyDialog() { NSApp.stopModal(withCode: .OK) }
    @objc private func cancelKeyDialog() { NSApp.stopModal(withCode: .cancel) }
}
