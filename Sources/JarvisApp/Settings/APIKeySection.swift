import AppKit
import JarvisCore

/// Settings panel for the OpenAI API key. Saves to the Keychain and reports back via `onKeySaved`
/// (the app restarts the pipeline only if it was already running). Replaces the old modal dialog in
/// MenuBarController.
@MainActor
final class APIKeySection: NSObject, SettingsSection {
    let title = "API Key"

    private let keychain: KeychainSecretStore
    private let onKeySaved: (String) -> Void
    private var field: NSSecureTextField?
    private var status: NSTextField?

    init(keychain: KeychainSecretStore, onKeySaved: @escaping (String) -> Void) {
        self.keychain = keychain
        self.onKeySaved = onKeySaved
    }

    func makeView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 432))

        let label = NSTextField(labelWithString: "Paste your OpenAI API key. It's stored in your Keychain.")
        label.frame = NSRect(x: 24, y: 360, width: 512, height: 20)
        view.addSubview(label)

        let field = NSSecureTextField(frame: NSRect(x: 24, y: 322, width: 512, height: 26))
        field.placeholderString = "sk-…"
        view.addSubview(field)
        self.field = field

        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.frame = NSRect(x: 444, y: 282, width: 92, height: 32)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        view.addSubview(save)

        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 24, y: 288, width: 400, height: 20)
        status.textColor = .secondaryLabelColor
        view.addSubview(status)
        self.status = status

        return view
    }

    @objc private func saveTapped() {
        let token = (field?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { status?.stringValue = "Enter a key first."; return }
        keychain.setApiKey(token)
        onKeySaved(token)
        status?.stringValue = "Key saved ✓"
        field?.stringValue = ""
    }
}
