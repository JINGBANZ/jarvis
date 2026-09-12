import AppKit
import JarvisCore

/// Jarvis-managed credential editor used by Connections Settings. One instance per `Credential`.
@MainActor
final class APIKeyControls: NSObject {
    private let credential: Credential
    private let store: FileSecretStore
    private let onKeySaved: (Credential, String) -> Void

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
    private var verdictLabel: NSTextField?
    /// What the provider said about the key just saved, kept until the key is edited again. `nil`
    /// means nothing has been checked in this window, which is not the same as "fine".
    private var verdict: Verdict?
    private var verdictTask: Task<Void, Never>?

    private enum Verdict {
        case checking(String)
        case answered(CredentialCheck.Verdict, text: String)

        var text: String {
            switch self {
            case .checking(let text): text
            case .answered(_, let text): text
            }
        }

        var color: NSColor {
            switch self {
            case .checking: .secondaryLabelColor
            case .answered(.accepted, _): .systemGreen
            case .answered(.rejected, _): .systemRed
            case .answered(.inconclusive, _): .systemOrange
            }
        }
    }

    private static let collapsedHeight = SettingsStyle.cardHeaderHeight + SettingsStyle.rowHeight
    private static let editorHeight: CGFloat = 64

    var preferredHeight: CGFloat {
        Self.collapsedHeight + (editing ? Self.editorHeight : 0)
            + (verdict != nil ? SettingsStyle.rowHeight : 0)
    }

    var hasSavedKey: Bool { store.apiKey(for: credential) != nil }

    init(credential: Credential, store: FileSecretStore, onKeySaved: @escaping (Credential, String) -> Void) {
        self.credential = credential
        self.store = store
        self.onKeySaved = onKeySaved
    }

    func makeView(onHeightChanged: @escaping (CGFloat) -> Void) -> NSView {
        editing = false
        self.onHeightChanged = onHeightChanged

        let card = SettingsCardView(
            frame: NSRect(x: 0, y: 0, width: 712, height: preferredHeight))
        card.setHeader(title: credential.displayName, detail: "Jarvis-managed credential")
        card.onLayout = { [weak self] in self?.layout() }
        self.card = card
        guard let content = card.contentView else { return card }

        let statusBadge = NSTextField(labelWithString: "Key saved")
        statusBadge.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        statusBadge.textColor = .systemGreen
        statusBadge.alignment = .right
        statusBadge.setAccessibilityLabel("\(credential.displayName) key saved")
        self.statusBadge = statusBadge

        let action = NSButton(
            title: hasSavedKey ? "Edit" : "Add API key",
            target: self,
            action: #selector(editTapped))
        action.bezelStyle = .rounded
        action.identifier = NSUserInterfaceItemIdentifier("\(credential.rawValue)-action")
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
        field.placeholderString = credential.placeholderHint
        field.setAccessibilityLabel("\(credential.displayName) API key")
        field.identifier = NSUserInterfaceItemIdentifier("\(credential.rawValue)-key-field")
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
        error.identifier = NSUserInterfaceItemIdentifier("\(credential.rawValue)-key-error")
        content.addSubview(error)
        errorLabel = error

        let verdictLabel = NSTextField(labelWithString: "")
        verdictLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        verdictLabel.lineBreakMode = .byTruncatingTail
        verdictLabel.identifier = NSUserInterfaceItemIdentifier("\(credential.rawValue)-key-verdict")
        content.addSubview(verdictLabel)
        self.verdictLabel = verdictLabel

        applyState()
        return card
    }

    func windowWillClose() {
        verdictTask?.cancel()
        verdictTask = nil
        // This object outlives the window and is reused on the next open, so a checking state left
        // behind would greet that open with a check no task is running. An answered verdict stays:
        // it is still what the provider said about the saved key.
        if case .checking = verdict { verdict = nil }
    }

    private func layout() {
        guard let card, let content = card.contentView else { return }
        let verdictOffset = verdict != nil ? SettingsStyle.rowHeight : 0
        let editorOffset = (editing ? Self.editorHeight : 0) + verdictOffset
        keyRow?.frame = NSRect(
            x: 0,
            y: editorOffset,
            width: content.bounds.width,
            height: SettingsStyle.rowHeight)
        if verdict != nil {
            verdictLabel?.frame = NSRect(
                x: SettingsStyle.rowHorizontalInset,
                y: (SettingsStyle.rowHeight - 18) / 2,
                width: max(160, content.bounds.width - SettingsStyle.rowHorizontalInset * 2),
                height: 18)
        }

        guard editing else { return }
        let buttonWidth: CGFloat = 82
        let buttonSpacing: CGFloat = 8
        let trailing = SettingsStyle.rowHorizontalInset
        let fieldWidth = min(310, max(170, content.bounds.width * 0.44))
        field?.frame = NSRect(
            x: SettingsStyle.rowHorizontalInset,
            y: verdictOffset + 28,
            width: fieldWidth,
            height: 26)
        cancelButton?.frame = NSRect(
            x: content.bounds.width - trailing - buttonWidth * 2 - buttonSpacing,
            y: verdictOffset + 25,
            width: buttonWidth,
            height: 32)
        saveButton?.frame = NSRect(
            x: content.bounds.width - trailing - buttonWidth,
            y: verdictOffset + 25,
            width: buttonWidth,
            height: 32)
        errorLabel?.frame = NSRect(
            x: SettingsStyle.rowHorizontalInset,
            y: verdictOffset + 5,
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
        verdictLabel?.isHidden = verdict == nil
        verdictLabel?.stringValue = verdict?.text ?? ""
        verdictLabel?.textColor = verdict?.color ?? .secondaryLabelColor
        card?.frame.size.height = preferredHeight
        card?.needsLayout = true
        layout()
        onHeightChanged?(preferredHeight)
    }

    @objc private func editTapped() {
        editing = true
        errorLabel?.stringValue = ""
        field?.stringValue = ""
        // A verdict belongs to the key that was checked. Editing starts a different key, so the old
        // answer stops being about anything on screen.
        verdictTask?.cancel()
        verdictTask = nil
        verdict = nil
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
        guard store.setApiKey(token, for: credential) else {
            errorLabel?.stringValue = "Couldn’t save the key."
            return
        }
        onKeySaved(credential, token)
        editing = false
        field?.stringValue = ""
        errorLabel?.stringValue = ""
        // The key is saved either way; the check only reports what the provider makes of it, so a
        // slow or failed check never blocks the save.
        verdict = .checking("Checking the key with \(credential.vendorName)…")
        applyState()
        verdictTask?.cancel()
        verdictTask = Task { [weak self, credential] in
            let result = await CredentialVerifier().check(credential, key: token)
            guard let self, !Task.isCancelled else { return }
            self.verdict = .answered(
                result, text: CredentialCheck.statusText(result, for: credential))
            self.applyState()
        }
    }
}
