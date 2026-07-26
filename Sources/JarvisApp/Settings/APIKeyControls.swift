import AppKit
import JarvisCore

/// Minimal transcription-provider and OpenAI credential editor for Brain Settings.
///
/// The collapsed state communicates configuration through its action only: `Add API key` when
/// absent, `Edit` when present. Entry controls expand on explicit user action; errors appear only
/// when needed, so the normal Settings surface stays quiet.
@MainActor
final class APIKeyControls: NSObject {
    private let store: FileSecretStore
    private let onKeySaved: (String) -> Void

    private var card: SettingsCardView?
    private var onHeightChanged: ((CGFloat) -> Void)?
    private var editing = false
    private var providerPopup: NSPopUpButton?
    private var actionButton: NSButton?
    private var field: NSSecureTextField?
    private var saveButton: NSButton?
    private var cancelButton: NSButton?
    private var status: NSTextField?

    private static let collapsedHeight: CGFloat = 150
    private static let expandedHeight: CGFloat = 214

    var preferredHeight: CGFloat {
        editing ? Self.expandedHeight : Self.collapsedHeight
    }

    init(store: FileSecretStore, onKeySaved: @escaping (String) -> Void) {
        self.store = store
        self.onKeySaved = onKeySaved
    }

    func makeView(onHeightChanged: @escaping (CGFloat) -> Void) -> NSView {
        editing = false
        self.onHeightChanged = onHeightChanged

        let card = SettingsCardView(
            frame: NSRect(x: 0, y: 0, width: 712, height: preferredHeight))
        card.boxType = .custom
        card.borderWidth = 1
        card.cornerRadius = 12
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        card.contentViewMargins = .zero
        card.onLayout = { [weak self] in self?.layout() }
        self.card = card

        guard let content = card.contentView else { return card }

        let heading = NSTextField(labelWithString: "TRANSCRIPTION")
        heading.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        heading.textColor = .secondaryLabelColor
        heading.setAccessibilityLabel("Transcription")
        heading.identifier = NSUserInterfaceItemIdentifier("transcription-heading")
        content.addSubview(heading)

        let providerLabel = NSTextField(labelWithString: "Provider")
        providerLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        providerLabel.identifier = NSUserInterfaceItemIdentifier("transcription-provider-label")
        content.addSubview(providerLabel)

        let provider = NSPopUpButton()
        provider.addItem(withTitle: BrainProvider.openAI.displayName)
        provider.setAccessibilityLabel("Transcription provider")
        provider.identifier = NSUserInterfaceItemIdentifier("transcription-provider")
        content.addSubview(provider)
        providerPopup = provider

        let keyLabel = NSTextField(labelWithString: "API key")
        keyLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        keyLabel.identifier = NSUserInterfaceItemIdentifier("transcription-key-label")
        content.addSubview(keyLabel)

        let action = NSButton(
            title: store.apiKey() == nil ? "Add API key" : "Edit",
            target: self,
            action: #selector(editTapped))
        action.bezelStyle = .rounded
        action.identifier = NSUserInterfaceItemIdentifier("transcription-key-action")
        content.addSubview(action)
        actionButton = action

        let field = NSSecureTextField()
        field.placeholderString = "sk-…"
        field.setAccessibilityLabel("OpenAI API key")
        field.identifier = NSUserInterfaceItemIdentifier("transcription-key-field")
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

        let status = NSTextField(labelWithString: "")
        status.textColor = .systemRed
        status.identifier = NSUserInterfaceItemIdentifier("transcription-key-error")
        content.addSubview(status)
        self.status = status

        applyState()
        layout()
        return card
    }

    private func layout() {
        guard let card, let content = card.contentView else { return }
        let width = content.bounds.width
        let height = preferredHeight
        let controlWidth: CGFloat = min(220, max(150, width * 0.46))
        let controlX = width - 14 - controlWidth

        content.subviews.first {
            $0.identifier?.rawValue == "transcription-heading"
        }?.frame = NSRect(x: 16, y: height - 30, width: width - 32, height: 18)
        content.subviews.first {
            $0.identifier?.rawValue == "transcription-provider-label"
        }?.frame = NSRect(x: 16, y: height - 74, width: 150, height: 20)
        providerPopup?.frame = NSRect(
            x: controlX, y: height - 80, width: controlWidth, height: 32)
        content.subviews.first {
            $0.identifier?.rawValue == "transcription-key-label"
        }?.frame = NSRect(x: 16, y: height - 128, width: 150, height: 20)

        if editing {
            field?.frame = NSRect(
                x: controlX, y: height - 134, width: controlWidth, height: 26)
            saveButton?.frame = NSRect(
                x: width - 14 - 82, y: 31, width: 82, height: 32)
            cancelButton?.frame = NSRect(
                x: width - 14 - 172, y: 31, width: 82, height: 32)
            status?.frame = NSRect(
                x: 16, y: 8, width: max(160, width - 206), height: 20)
        } else {
            actionButton?.sizeToFit()
            let actionWidth = max(82, (actionButton?.frame.width ?? 0) + 20)
            actionButton?.frame = NSRect(
                x: width - 14 - actionWidth,
                y: height - 134,
                width: actionWidth,
                height: 32)
        }
    }

    private func applyState() {
        actionButton?.isHidden = editing
        field?.isHidden = !editing
        saveButton?.isHidden = !editing
        cancelButton?.isHidden = !editing
        status?.isHidden = !editing
        card?.frame.size.height = preferredHeight
        card?.needsLayout = true
        onHeightChanged?(preferredHeight)
    }

    @objc private func editTapped() {
        editing = true
        status?.stringValue = ""
        field?.stringValue = ""
        applyState()
        layout()
        field?.window?.makeFirstResponder(field)
    }

    @objc private func cancelTapped() {
        editing = false
        status?.stringValue = ""
        field?.stringValue = ""
        applyState()
        layout()
    }

    @objc private func saveTapped() {
        let token = (field?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            status?.stringValue = "Enter a key first."
            return
        }
        guard store.setApiKey(token) else {
            status?.stringValue = "Couldn’t save the key."
            return
        }
        onKeySaved(token)
        field?.stringValue = ""
        editing = false
        actionButton?.title = "Edit"
        applyState()
        layout()
    }
}
