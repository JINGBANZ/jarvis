import AppKit
import JarvisCore

/// The OpenAI API-key controls embedded in the Brain settings tab. Saves to an owner-only file and
/// reports back via `onKeySaved` (the app applies it without restarting a live conversation).
///
/// Two states: when no key is stored yet it shows the entry field + Save; when one already exists it
/// shows a "key is saved" summary + an Edit button (we never display the stored key — it's write-only,
/// matching the owner-only-file posture). Edit reveals an empty field to paste a replacement.
@MainActor
final class APIKeyControls: NSObject {
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

    /// Add the control rows to `view`, laid out downward from `top` (the y of the first row).
    ///
    /// The caller supplies the horizontal content bounds so the same controls fit a grouped card
    /// and continue resizing with the Settings window.
    func addControls(to view: NSView, top: CGFloat, x: CGFloat, width: CGFloat) {
        let prompt = NSTextField(labelWithString: "Paste your OpenAI API key.")
        prompt.frame = NSRect(x: x, y: top, width: width, height: 20)
        prompt.autoresizingMask = [.width]
        view.addSubview(prompt)
        self.prompt = prompt

        let field = NSSecureTextField(frame: NSRect(x: x, y: top - 38, width: width, height: 26))
        field.autoresizingMask = [.width]
        field.placeholderString = "sk-…"
        field.setAccessibilityLabel("OpenAI API key")
        view.addSubview(field)
        self.field = field

        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.frame = NSRect(x: x + width - 92, y: top - 78, width: 92, height: 32)
        save.autoresizingMask = [.minXMargin]
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        view.addSubview(save)
        self.saveButton = save

        // Sits just left of Save; only meaningful when a key already exists, so canceling has a saved
        // state to return to (a first-time entry has nothing to cancel back to).
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.frame = NSRect(x: x + width - 192, y: top - 78, width: 92, height: 32)
        cancel.autoresizingMask = [.minXMargin]
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}" // Esc
        view.addSubview(cancel)
        self.cancelButton = cancel

        let savedLabel = NSTextField(labelWithString: "An OpenAI API key is saved on this Mac.")
        savedLabel.frame = NSRect(x: x, y: top, width: width, height: 20)
        savedLabel.autoresizingMask = [.width]
        view.addSubview(savedLabel)
        self.savedLabel = savedLabel

        let edit = NSButton(title: "Edit", target: self, action: #selector(editTapped))
        edit.frame = NSRect(x: x, y: top - 42, width: 92, height: 32)
        edit.bezelStyle = .rounded
        view.addSubview(edit)
        self.editButton = edit

        // Below the Save/Cancel row — at the buttons' own height its frame would overlap (and, being
        // a later subview, swallow clicks on) the Cancel button.
        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: x, y: top - 110, width: width, height: 20)
        status.autoresizingMask = [.width]
        status.textColor = .secondaryLabelColor
        view.addSubview(status)
        self.status = status

        editing = store.apiKey() == nil
        applyState()
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
