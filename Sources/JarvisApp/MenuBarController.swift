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

    @objc private func setKey() {
        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Stored in your login Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            keychain.setApiKey(key)            // saved locally in the login Keychain
            statusItem.button?.title = "🟢 Jarvis"
            onKeySaved?(key)                    // start coaching now — no relaunch needed
        }
    }
}
