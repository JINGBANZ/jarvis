import AppKit
import JarvisCore

/// Jarvis-managed OpenAI credential editor used by Connections Settings.
@MainActor
final class APIKeyControls: NSObject {
    private let store: FileSecretStore
    private let onKeySaved: (String) -> Void

    private var card: SettingsCardView?
    private var keyRow: SettingsRowView?
    private var onHeightChanged: ((CGFloat) -> Void)?
    private var editing = false
    private var statusBadge: NSTextField?
    private var actionButton: NSButton?
    private var field: NSSecureTextField?
    private var saveButton: NSButton?
    private var cancelButton: NSButton?
    private var errorLabel: NSTextField?

    private static let collapsedHeight = SettingsStyle.cardHeaderHeight + SettingsStyle.rowHeight
    private static let editorHeight: CGFloat = 64

    var preferredHeight: CGFloat {
        Self.collapsedHeight + (editing ? Self.editorHeight : 0)
    }

    var hasSavedKey: Bool { store.apiKey() != nil }

    init(store: FileSecretStore, onKeySaved: @escaping (String) -> Void) {
        self.store = store
        self.onKeySaved = onKeySaved
    }

    func makeView(onHeightChanged: @escaping (CGFloat) -> Void) -> NSView {
        editing = false
        self.onHeightChanged = onHeightChanged

        let card = SettingsCardView(
            frame: NSRect(x: 0, y: 0, width: 712, height: preferredHeight))
        card.setHeader(title: "OpenAI API", detail: "Jarvis-managed credential")
        card.onLayout = { [weak self] in self?.layout() }
        self.card = card
        guard let content = card.contentView else { return card }

        let statusBadge = NSTextField(labelWithString: "Key saved")
        statusBadge.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        statusBadge.textColor = .systemGreen
        statusBadge.alignment = .right
        statusBadge.setAccessibilityLabel("OpenAI API key saved")
        self.statusBadge = statusBadge

        let action = NSButton(
            title: hasSavedKey ? "Edit" : "Add API key",
            target: self,
            action: #selector(editTapped))
        action.bezelStyle = .rounded
        action.identifier = NSUserInterfaceItemIdentifier("openai-key-action")
        self.actionButton = action

        let trailingControls = NSStackView(views: [statusBadge, action])
        trailingControls.orientation = .horizontal
        trailingControls.alignment = .centerY
        trailingControls.spacing = 8
        statusBadge.setContentHuggingPriority(.required, for: .horizontal)
        action.setContentHuggingPriority(.required, for: .horizontal)

        let controls = NSView()
        trailingControls.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(trailingControls)
        NSLayoutConstraint.activate([
            trailingControls.leadingAnchor.constraint(greaterThanOrEqualTo: controls.leadingAnchor),
            trailingControls.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            trailingControls.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
        ])
        let row = SettingsRowView(
            title: "API key",
            controlView: controls,
            controlSize: NSSize(width: 220, height: 32),
            showsSeparator: false)
        content.addSubview(row)
        keyRow = row

        let field = NSSecureTextField()
        field.placeholderString = "sk-…"
        field.setAccessibilityLabel("OpenAI API key")
        field.identifier = NSUserInterfaceItemIdentifier("openai-key-field")
        content.addSubview(field)
        self.field = field

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        content.addSubview(cancel)
        cancelButton = cancel

        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        content.addSubview(save)
        saveButton = save

        let error = NSTextField(labelWithString: "")
        error.textColor = .systemRed
        error.identifier = NSUserInterfaceItemIdentifier("openai-key-error")
        content.addSubview(error)
        errorLabel = error

        applyState()
        return card
    }

    private func layout() {
        guard let card, let content = card.contentView else { return }
        let editorOffset = editing ? Self.editorHeight : 0
        keyRow?.frame = NSRect(
            x: 0,
            y: editorOffset,
            width: content.bounds.width,
            height: SettingsStyle.rowHeight)

        guard editing else { return }
        let buttonWidth: CGFloat = 82
        let buttonSpacing: CGFloat = 8
        let trailing = SettingsStyle.rowHorizontalInset
        let fieldWidth = min(310, max(170, content.bounds.width * 0.44))
        field?.frame = NSRect(
            x: SettingsStyle.rowHorizontalInset,
            y: 28,
            width: fieldWidth,
            height: 26)
        cancelButton?.frame = NSRect(
            x: content.bounds.width - trailing - buttonWidth * 2 - buttonSpacing,
            y: 25,
            width: buttonWidth,
            height: 32)
        saveButton?.frame = NSRect(
            x: content.bounds.width - trailing - buttonWidth,
            y: 25,
            width: buttonWidth,
            height: 32)
        errorLabel?.frame = NSRect(
            x: SettingsStyle.rowHorizontalInset,
            y: 5,
            width: max(160, content.bounds.width - SettingsStyle.rowHorizontalInset * 2),
            height: 18)
    }

    private func applyState() {
        statusBadge?.isHidden = !hasSavedKey || editing
        actionButton?.isHidden = editing
        actionButton?.title = hasSavedKey ? "Edit" : "Add API key"
        field?.isHidden = !editing
        saveButton?.isHidden = !editing
        cancelButton?.isHidden = !editing
        errorLabel?.isHidden = !editing
        card?.frame.size.height = preferredHeight
        card?.needsLayout = true
        layout()
        onHeightChanged?(preferredHeight)
    }

    @objc private func editTapped() {
        editing = true
        errorLabel?.stringValue = ""
        field?.stringValue = ""
        applyState()
        field?.window?.makeFirstResponder(field)
    }

    @objc private func cancelTapped() {
        editing = false
        errorLabel?.stringValue = ""
        field?.stringValue = ""
        applyState()
    }

    @objc private func saveTapped() {
        let token = (field?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorLabel?.stringValue = "Enter a key first."
            return
        }
        guard store.setApiKey(token) else {
            errorLabel?.stringValue = "Couldn’t save the key."
            return
        }
        onKeySaved(token)
        editing = false
        field?.stringValue = ""
        errorLabel?.stringValue = ""
        applyState()
    }
}
