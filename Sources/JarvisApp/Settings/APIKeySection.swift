import AppKit
import JarvisCore

/// Settings panel for the OpenAI API key. Saves to an owner-only file and reports back via
/// `onKeySaved` (the app restarts the pipeline only if it was already running). Replaces the old modal
/// dialog in MenuBarController.
///
/// Two states: when no key is stored yet it shows the entry field + Save; when one already exists it
/// shows a "key is saved" summary + an Edit button (we never display the stored key — it's write-only,
/// matching the owner-only-file posture). Edit reveals an empty field to paste a replacement.
@MainActor
final class APIKeySection: NSObject, SettingsSection {
    let title = "API Key"

    private let store: FileSecretStore
    private let onKeySaved: (String) -> Void

    private var prompt: NSTextField?           // entry instructions
    private var field: NSSecureTextField?
    private var saveButton: NSButton?
    private var cancelButton: NSButton?        // shown only when editing an existing key
    private var savedLabel: NSTextField?       // "a key is saved" summary
    private var editButton: NSButton?
    private var status: NSTextField?

    /// When true the entry field is shown; when false the saved summary is. Starts in entry mode only
    /// if no key exists yet.
    private var editing = true

    init(store: FileSecretStore, onKeySaved: @escaping (String) -> Void) {
        self.store = store
        self.onKeySaved = onKeySaved
    }

    func makeView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 432))

        let prompt = NSTextField(labelWithString: "Paste your OpenAI API key to unlock OpenAI model.")
        prompt.frame = NSRect(x: 24, y: 360, width: 512, height: 20)
        view.addSubview(prompt)
        self.prompt = prompt

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
        self.saveButton = save

        // Sits just left of Save; only meaningful when a key already exists, so canceling has a saved
        // state to return to (a first-time entry has nothing to cancel back to).
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.frame = NSRect(x: 344, y: 282, width: 92, height: 32)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}" // Esc
        view.addSubview(cancel)
        self.cancelButton = cancel

        let savedLabel = NSTextField(labelWithString: "An OpenAI API key is saved on this Mac.")
        savedLabel.frame = NSRect(x: 24, y: 360, width: 512, height: 20)
        view.addSubview(savedLabel)
        self.savedLabel = savedLabel

        let edit = NSButton(title: "Edit", target: self, action: #selector(editTapped))
        edit.frame = NSRect(x: 24, y: 318, width: 92, height: 32)
        edit.bezelStyle = .rounded
        view.addSubview(edit)
        self.editButton = edit

        // Below the Save/Cancel row — at the buttons' own height its frame would overlap (and, being
        // a later subview, swallow clicks on) the Cancel button.
        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 24, y: 248, width: 512, height: 20)
        status.textColor = .secondaryLabelColor
        view.addSubview(status)
        self.status = status

        editing = store.apiKey() == nil
        applyState()
        return view
    }

    /// Show the entry field + Save, or the saved summary + Edit, per `editing`. Cancel appears only
    /// while editing a key that's already stored — a first-time entry has no saved state to revert to.
    private func applyState() {
        prompt?.isHidden = !editing
        field?.isHidden = !editing
        saveButton?.isHidden = !editing
        cancelButton?.isHidden = !(editing && store.apiKey() != nil)
        savedLabel?.isHidden = editing
        editButton?.isHidden = editing
    }

    @objc private func editTapped() {
        editing = true
        status?.stringValue = ""
        field?.stringValue = ""
        applyState()
        field?.window?.makeFirstResponder(field)
    }

    @objc private func cancelTapped() {
        editing = false
        status?.stringValue = ""
        field?.stringValue = ""
        applyState()
    }

    @objc private func saveTapped() {
        let token = (field?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { status?.stringValue = "Enter a key first."; return }
        guard store.setApiKey(token) else { status?.stringValue = "Couldn't save key — check disk permissions."; return }
        onKeySaved(token)
        status?.stringValue = "Key saved ✓"
        field?.stringValue = ""
        editing = false
        applyState()
    }
}
