import AppKit
import JarvisCore

/// Settings panel for the OpenAI API key. Saves to an owner-only file and reports back via
/// `onKeySaved` (the app restarts the pipeline only if it was already running). Replaces the old modal
/// dialog in MenuBarController.
@MainActor
final class APIKeySection: NSObject, SettingsSection {
    let title = "API Key"

    private let store: FileSecretStore
    private let onKeySaved: (String) -> Void
    private var field: NSSecureTextField?
    private var status: NSTextField?

    init(store: FileSecretStore, onKeySaved: @escaping (String) -> Void) {
        self.store = store
        self.onKeySaved = onKeySaved
    }

    func makeView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 432))

        let label = NSTextField(labelWithString: "Paste your OpenAI API key. It's stored in an owner-only file on this Mac.")
        label.frame = NSRect(x: 24, y: 360, width: 512, height: 20)
        view.addSubview(label)

        let field = NSSecureTextField(frame: NSRect(x: 24, y: 322, width: 512, height: 26))
        field.placeholderString = "sk-…"
        field.setAccessibilityLabel("OpenAI API key")
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
        guard store.setApiKey(token) else { status?.stringValue = "Couldn't save key — check disk permissions."; return }
        onKeySaved(token)
        status?.stringValue = "Key saved ✓"
        field?.stringValue = ""
    }
}
