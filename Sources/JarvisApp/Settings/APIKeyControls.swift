import AppKit
import JarvisCore
#if compiler(>=6.2) && canImport(FoundationModels) && canImport(Speech) && !JARVIS_FORCE_APPLE_SPEECH_FALLBACK
@preconcurrency import Speech
#endif

/// Transcription-provider and OpenAI credential editor for Brain Settings.
///
/// The collapsed state communicates configuration through its action only: `Add API key` when
/// absent, `Edit` when present. Entry controls expand on explicit user action; errors appear only
/// when needed, so the normal Settings surface stays quiet.
@MainActor
final class APIKeyControls: NSObject {
    private let store: FileSecretStore
    private let preferences: TranscriptionPreferences
    private let onKeySaved: (String) -> Void

    private var card: SettingsCardView?
    private var onHeightChanged: ((CGFloat) -> Void)?
    private var editing = false
    private var providerPopup: NSPopUpButton?
    private var modelLabel: NSTextField?
    private var modelPopup: NSPopUpButton?
    private var languageLabel: NSTextField?
    private var languagePopup: NSPopUpButton?
    private var localeLabel: NSTextField?
    private var localePopup: NSPopUpButton?
    private var guidance: NSTextField?
    private var actionButton: NSButton?
    private var field: NSSecureTextField?
    private var saveButton: NSButton?
    private var cancelButton: NSButton?
    private var status: NSTextField?
    private var rowSeparator: NSBox?
    private var localeLoadTask: Task<Void, Never>?

    private static let openAICollapsedHeight: CGFloat = 330
    private static let appleSpeechCollapsedHeight: CGFloat = 284
    private static let editorHeight: CGFloat = 64

    var preferredHeight: CGFloat {
        let collapsed = preferences.provider == .openAI
            ? Self.openAICollapsedHeight
            : Self.appleSpeechCollapsedHeight
        return collapsed + (editing ? Self.editorHeight : 0)
    }

    init(
        store: FileSecretStore,
        preferences: TranscriptionPreferences,
        onKeySaved: @escaping (String) -> Void
    ) {
        self.store = store
        self.preferences = preferences
        self.onKeySaved = onKeySaved
    }

    func makeView(onHeightChanged: @escaping (CGFloat) -> Void) -> NSView {
        editing = false
        self.onHeightChanged = onHeightChanged

        let card = SettingsCardView(
            frame: NSRect(x: 0, y: 0, width: 712, height: preferredHeight))
        card.setHeader(title: "Transcription", detail: "What Jarvis hears")
        card.onLayout = { [weak self] in self?.layout() }
        self.card = card

        guard let content = card.contentView else { return card }

        let providerLabel = NSTextField(labelWithString: "Provider")
        providerLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        providerLabel.identifier = NSUserInterfaceItemIdentifier("transcription-provider-label")
        content.addSubview(providerLabel)

        let provider = NSPopUpButton()
        for choice in TranscriptionProvider.allCases {
            let title = choice == .appleSpeech
                ? "\(choice.displayName) (macOS 26+)"
                : choice.displayName
            provider.addItem(withTitle: title)
            provider.lastItem?.representedObject = choice.rawValue
            if choice == .appleSpeech {
                provider.lastItem?.isEnabled = Self.appleSpeechIsAvailable
                provider.lastItem?.toolTip = Self.appleSpeechIsAvailable
                    ? "On-device transcription using one selected conversation locale"
                    : "Requires macOS 26 and Apple Speech support"
            }
        }
        if let selected = provider.itemArray.firstIndex(where: {
            $0.representedObject as? String == preferences.provider.rawValue
        }) {
            provider.selectItem(at: selected)
        }
        provider.target = self
        provider.action = #selector(providerChanged)
        provider.setAccessibilityLabel("Transcription provider")
        provider.identifier = NSUserInterfaceItemIdentifier("transcription-provider")
        content.addSubview(provider)
        providerPopup = provider

        let modelLabel = NSTextField(labelWithString: "Model")
        modelLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        content.addSubview(modelLabel)
        self.modelLabel = modelLabel

        let model = NSPopUpButton()
        for choice in OpenAITranscriptionModel.allCases {
            model.addItem(withTitle: choice.displayName)
            model.lastItem?.representedObject = choice.rawValue
        }
        if let selected = model.itemArray.firstIndex(where: {
            $0.representedObject as? String == preferences.openAIModel.rawValue
        }) {
            model.selectItem(at: selected)
        }
        model.target = self
        model.action = #selector(modelChanged)
        model.setAccessibilityLabel("OpenAI transcription model")
        model.identifier = NSUserInterfaceItemIdentifier("transcription-model")
        content.addSubview(model)
        modelPopup = model

        let languageLabel = NSTextField(labelWithString: "Expected languages")
        languageLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        content.addSubview(languageLabel)
        self.languageLabel = languageLabel

        let language = NSPopUpButton()
        for choice in OpenAITranscriptionLanguageProfile.allCases {
            language.addItem(withTitle: choice.displayName)
            language.lastItem?.representedObject = choice.rawValue
        }
        if let selected = language.itemArray.firstIndex(where: {
            $0.representedObject as? String
                == preferences.openAILanguageProfile.rawValue
        }) {
            language.selectItem(at: selected)
        }
        language.target = self
        language.action = #selector(languageChanged)
        language.setAccessibilityLabel("Expected transcription languages")
        language.identifier = NSUserInterfaceItemIdentifier("transcription-languages")
        content.addSubview(language)
        languagePopup = language

        let localeLabel = NSTextField(labelWithString: "Conversation locale")
        localeLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        content.addSubview(localeLabel)
        self.localeLabel = localeLabel

        let locale = NSPopUpButton()
        locale.addItem(withTitle: "Loading locales…")
        locale.isEnabled = false
        locale.target = self
        locale.action = #selector(localeChanged)
        locale.setAccessibilityLabel("Apple Speech conversation locale")
        locale.identifier = NSUserInterfaceItemIdentifier("transcription-locale")
        content.addSubview(locale)
        localePopup = locale

        let guidance = NSTextField(wrappingLabelWithString: "")
        guidance.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        guidance.textColor = .secondaryLabelColor
        guidance.maximumNumberOfLines = 2
        guidance.lineBreakMode = .byWordWrapping
        content.addSubview(guidance)
        self.guidance = guidance

        let keyLabel = NSTextField(labelWithString: "OpenAI API key")
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

        let separator = SettingsStyle.separator()
        content.addSubview(separator)
        rowSeparator = separator

        if preferences.provider == .appleSpeech {
            loadAppleSpeechLocales()
        }
        applyState()
        layout()
        return card
    }

    private func layout() {
        guard let card, let content = card.contentView else { return }
        let width = content.bounds.width
        let height = preferredHeight
        let controlWidth: CGFloat = min(280, max(180, width * 0.46))
        let controlX = width - 14 - controlWidth
        let bodyTop = height - card.headerHeight
        let providerRowY = bodyTop - SettingsStyle.rowHeight
        let usesOpenAI = preferences.provider == .openAI
        let modelOrLocaleRowY = providerRowY - 46
        let languageRowY = modelOrLocaleRowY - 46
        let guidanceRowY = (usesOpenAI ? languageRowY : modelOrLocaleRowY) - 54
        let keyRowY = guidanceRowY - SettingsStyle.rowHeight

        content.subviews.first {
            $0.identifier?.rawValue == "transcription-provider-label"
        }?.frame = NSRect(x: 16, y: providerRowY + 18, width: 150, height: 20)
        providerPopup?.frame = NSRect(
            x: controlX, y: providerRowY + 11, width: controlWidth, height: 32)
        modelLabel?.frame = NSRect(
            x: 16, y: modelOrLocaleRowY + 18, width: 180, height: 20)
        modelPopup?.frame = NSRect(
            x: controlX, y: modelOrLocaleRowY + 11, width: controlWidth, height: 32)
        languageLabel?.frame = NSRect(
            x: 16, y: languageRowY + 18, width: 180, height: 20)
        languagePopup?.frame = NSRect(
            x: controlX, y: languageRowY + 11, width: controlWidth, height: 32)
        localeLabel?.frame = NSRect(
            x: 16, y: modelOrLocaleRowY + 18, width: 180, height: 20)
        localePopup?.frame = NSRect(
            x: controlX, y: modelOrLocaleRowY + 11, width: controlWidth, height: 32)
        guidance?.frame = NSRect(
            x: 16, y: guidanceRowY + 7, width: width - 32, height: 40)
        content.subviews.first {
            $0.identifier?.rawValue == "transcription-key-label"
        }?.frame = NSRect(x: 16, y: keyRowY + 18, width: 150, height: 20)
        rowSeparator?.frame = NSRect(
            x: 16, y: providerRowY, width: width - 16, height: 1)

        if editing {
            field?.frame = NSRect(
                x: controlX, y: keyRowY + 15, width: controlWidth, height: 26)
            saveButton?.frame = NSRect(
                x: width - 14 - 82, y: 16, width: 82, height: 32)
            cancelButton?.frame = NSRect(
                x: width - 14 - 172, y: 16, width: 82, height: 32)
            status?.frame = NSRect(
                x: 16, y: 22, width: max(160, width - 206), height: 20)
        } else {
            actionButton?.sizeToFit()
            let actionWidth = max(82, (actionButton?.frame.width ?? 0) + 20)
            actionButton?.frame = NSRect(
                x: width - 14 - actionWidth,
                y: keyRowY + 11,
                width: actionWidth,
                height: 32)
        }
    }

    private func applyState() {
        let usesOpenAI = preferences.provider == .openAI
        modelLabel?.isHidden = !usesOpenAI
        modelPopup?.isHidden = !usesOpenAI
        languageLabel?.isHidden = !usesOpenAI
        languagePopup?.isHidden = !usesOpenAI
        localeLabel?.isHidden = usesOpenAI
        localePopup?.isHidden = usesOpenAI
        guidance?.stringValue = guidanceText
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

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let provider = TranscriptionProvider(rawValue: raw) else {
            return
        }
        preferences.provider = provider
        jlog("Jarvis: \(provider.displayName) transcription selected for the next Start.")
        if provider == .appleSpeech,
           localePopup?.selectedItem?.representedObject == nil {
            loadAppleSpeechLocales()
        }
        applyState()
        layout()
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let model = OpenAITranscriptionModel(rawValue: raw) else {
            return
        }
        preferences.openAIModel = model
        jlog("Jarvis: \(model.displayName) selected for the next Start.")
        applyState()
        layout()
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let profile = OpenAITranscriptionLanguageProfile(rawValue: raw) else {
            return
        }
        preferences.openAILanguageProfile = profile
        jlog(
            "Jarvis: \(profile.displayName) transcription languages selected "
                + "for the next Start.")
        applyState()
        layout()
    }

    @objc private func localeChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.selectedItem?.representedObject as? String else {
            return
        }
        preferences.appleSpeechLocaleIdentifier = identifier
        jlog("Jarvis: Apple Speech locale \(identifier) selected for the next Start.")
    }

    @objc private func cancelTapped() {
        editing = false
        status?.stringValue = ""
        field?.stringValue = ""
        applyState()
        layout()
    }

    private var guidanceText: String {
        switch preferences.provider {
        case .appleSpeech:
            "Apple Speech uses one locale for the whole session. Choose the primary locale; use OpenAI for English–Mandarin code-switching."
        case .openAI:
            switch preferences.openAILanguageProfile {
            case .automatic:
                "No language hint is sent. The transcription model detects the spoken language."
            case .english, .mandarinChinese:
                "This hint guides recognition when it matches the conversation; it does not translate the transcript."
            case .englishAndMandarinChinese:
                if preferences.openAIModel == .gpt4oTranscribe {
                    "GPT-4o accepts one language hint, so this mixed profile uses automatic detection."
                } else {
                    "Both languages are hinted to \(preferences.openAIModel.displayName); either speaker may switch within a sentence."
                }
            }
        }
    }

    private func loadAppleSpeechLocales() {
        localeLoadTask?.cancel()
        #if compiler(>=6.2) && canImport(FoundationModels) && canImport(Speech) && !JARVIS_FORCE_APPLE_SPEECH_FALLBACK
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else {
            markLocalesUnavailable()
            return
        }

        localePopup?.removeAllItems()
        localePopup?.addItem(withTitle: "Loading locales…")
        localePopup?.isEnabled = false
        let preferredIdentifier = preferences.appleSpeechLocaleIdentifier
        localeLoadTask = Task { [weak self] in
            let locales = await SpeechTranscriber.supportedLocales
            let preferred = Locale(identifier: preferredIdentifier)
            let equivalent = await SpeechTranscriber.supportedLocale(
                equivalentTo: preferred)
            guard !Task.isCancelled, let self else { return }
            populateAppleSpeechLocales(
                locales,
                selectedIdentifier: equivalent?.identifier)
        }
        #else
        // Older SDK: the Speech APIs aren't compiled, so locale discovery is unavailable.
        markLocalesUnavailable()
        #endif
    }

    private func markLocalesUnavailable() {
        localePopup?.removeAllItems()
        localePopup?.addItem(withTitle: "Unavailable")
        localePopup?.isEnabled = false
    }

    private func populateAppleSpeechLocales(
        _ locales: [Locale],
        selectedIdentifier: String?
    ) {
        guard let localePopup else { return }
        localePopup.removeAllItems()
        localePopup.addItem(withTitle: "Choose locale…")

        let sortedLocales = locales.sorted {
            Self.localeTitle($0).localizedCaseInsensitiveCompare(
                Self.localeTitle($1)) == .orderedAscending
        }
        for locale in sortedLocales {
            localePopup.addItem(withTitle: Self.localeTitle(locale))
            localePopup.lastItem?.representedObject = locale.identifier
            localePopup.lastItem?.toolTip = locale.identifier
        }
        localePopup.isEnabled = !sortedLocales.isEmpty

        if let selectedIdentifier,
           let selected = localePopup.itemArray.firstIndex(where: {
               $0.representedObject as? String == selectedIdentifier
           }) {
            localePopup.selectItem(at: selected)
        } else {
            localePopup.selectItem(at: 0)
        }
    }

    private static func localeTitle(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
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

    private static var appleSpeechIsAvailable: Bool {
        #if compiler(>=6.2) && canImport(FoundationModels) && canImport(Speech) && !JARVIS_FORCE_APPLE_SPEECH_FALLBACK
        if #available(macOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        #endif
        return false
    }
}
