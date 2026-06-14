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
    /// Fired by "Show Test Tip" — renders a sample coaching overlay with no API call.
    var onTestTip: (() -> Void)?

    init(guardrails: Guardrails, keychain: KeychainSecretStore) {
        self.guardrails = guardrails
        self.keychain = keychain
        super.init()
        statusItem.button?.title = "🟢 Jarvis"
        let menu = NSMenu()
        let mute = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "m")
        mute.target = self
        menu.addItem(mute)
        // Primary, reliable path: read the key from the clipboard (no text-field focus issues).
        let paste = NSMenuItem(title: "Paste API Key from Clipboard", action: #selector(pasteKeyFromClipboard), keyEquivalent: "v")
        paste.target = self
        menu.addItem(paste)
        let key = NSMenuItem(title: "Set OpenAI API Key (type)…", action: #selector(setKey), keyEquivalent: "k")
        key.target = self
        menu.addItem(key)
        menu.addItem(.separator())
        let test = NSMenuItem(title: "Show Test Tip (no API)", action: #selector(showTestTip), keyEquivalent: "t")
        test.target = self
        menu.addItem(test)
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

    @objc private func showTestTip() {
        onTestTip?()
    }

    /// Reliable key entry: read the key straight from the clipboard — no text-field focus needed.
    @objc private func pasteKeyFromClipboard() {
        let token = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            confirm("Clipboard is empty",
                    "Copy your OpenAI API key first (it starts with “sk-”), then choose “Paste API Key from Clipboard” again.")
            return
        }
        let looksLikeKey = token.count >= 20 && !token.contains(where: { $0.isWhitespace })
        guard looksLikeKey else {
            confirm("That doesn't look like an API key",
                    "The clipboard should hold just your OpenAI key — one long token with no spaces. Copy it and try again.")
            return
        }
        keychain.setApiKey(token)
        statusItem.button?.title = "🟢 Jarvis"
        onKeySaved?(token)
        let hint = token.hasPrefix("sk-") ? "" : " (note: it didn’t start with “sk-” — if Jarvis can’t connect, re-copy your key.)"
        confirm("API key saved", "Stored in your Keychain. Jarvis is starting up — talk through a problem and it will coach you.\(hint)")
    }

    /// A mouse-clickable confirmation (OK only) — works regardless of keyboard focus.
    private func confirm(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        let nowMuted = !guardrails.isMuted
        guardrails.setMuted(nowMuted)
        sender.state = nowMuted ? .on : .off
        statusItem.button?.title = nowMuted ? "🔇 Jarvis" : "🟢 Jarvis"
        onMuteChanged?(nowMuted)
    }

    @objc private func setKey() {
        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Stored in your login Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        // An accessory (menu-bar-only) app can't reliably become the active/key app, so its modal
        // won't receive keyboard input or paste. Temporarily promote to a regular foreground app
        // for the duration of the dialog, then drop back to menu-bar-only.
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            keychain.setApiKey(key)            // saved locally in the login Keychain
            statusItem.button?.title = "🟢 Jarvis"
            onKeySaved?(key)                    // start coaching now — no relaunch needed
        }
    }
}
