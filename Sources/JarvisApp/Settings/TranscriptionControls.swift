import AppKit
import JarvisCore
#if compiler(>=6.2) && canImport(FoundationModels) && canImport(Speech) && !JARVIS_FORCE_APPLE_SPEECH_FALLBACK
@preconcurrency import Speech
#endif

/// Provider behavior for the Transcription card. Shared credentials are displayed and edited by
/// `ConnectionsSection`; this controller owns only Start-time transcription choices.
@MainActor
final class TranscriptionControls: NSObject {
    private let preferences: TranscriptionPreferences

    private var card: SettingsCardView?
    private var onHeightChanged: ((CGFloat) -> Void)?
    private var providerRow: SettingsRowView?
    private var modelRow: SettingsRowView?
    private var languagesRow: SettingsRowView?
    private var vocabularyRow: SettingsRowView?
    var vocabularyField: NSTextField?
    private var localeRow: SettingsRowView?
    private var localePopup: NSPopUpButton?
    private var localeLoadTask: Task<Void, Never>?

    var preferredHeight: CGFloat {
        SettingsStyle.cardHeaderHeight
            + CGFloat(preferences.provider == .openAI ? 4 : 2) * SettingsStyle.rowHeight
    }

    init(preferences: TranscriptionPreferences) {
        self.preferences = preferences
    }

    func makeView(onHeightChanged: @escaping (CGFloat) -> Void) -> NSView {
        localeLoadTask?.cancel()
        self.onHeightChanged = onHeightChanged

        let card = SettingsCardView(
            frame: NSRect(x: 0, y: 0, width: 712, height: preferredHeight))
        card.setHeader(title: "Transcription", detail: "What Jarvis hears")
        card.onLayout = { [weak self] in self?.layoutRows() }
        self.card = card
        guard let content = card.contentView else { return card }

        let provider = NSPopUpButton()
        for choice in TranscriptionProvider.allCases {
            provider.addItem(withTitle: choice == .appleSpeech
                ? "\(choice.displayName) (macOS 26+)"
                : choice.displayName)
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

        let providerRow = SettingsRowView(
            title: "Provider",
            detail: "Applies on the next Start",
            controlView: provider)
        content.addSubview(providerRow)
        self.providerRow = providerRow

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
        let modelRow = SettingsRowView(
            title: "Model",
            detail: "Speech-to-text model",
            controlView: model)
        content.addSubview(modelRow)
        self.modelRow = modelRow

        let languagePicker = ExpectedLanguagePicker(
            selectedLanguages: preferences.openAIExpectedLanguages,
            onChange: { [weak self] languages in self?.languagesChanged(languages) })
        languagePicker.identifier = NSUserInterfaceItemIdentifier("transcription-languages")
        let languagesRow = SettingsRowView(
            title: "Expected languages",
            detail: "No selection means automatic",
            controlView: languagePicker,
            controlSize: NSSize(width: 340, height: 32))
        content.addSubview(languagesRow)
        self.languagesRow = languagesRow

        let vocabularyField = NSTextField()
        vocabularyField.placeholderString = "e.g. Kubernetes, gRPC, Sun Xu"
        vocabularyField.stringValue = preferences.openAIVocabularyKeywords.joined(separator: ", ")
        vocabularyField.delegate = self
        vocabularyField.setAccessibilityLabel("Transcription vocabulary")
        vocabularyField.identifier = NSUserInterfaceItemIdentifier("transcription-vocabulary")
        let vocabularyRow = SettingsRowView(
            title: "Vocabulary",
            detail: "Only used by GPT Transcribe / GPT Live",
            controlView: vocabularyField,
            controlSize: NSSize(width: 340, height: 24))
        content.addSubview(vocabularyRow)
        self.vocabularyRow = vocabularyRow
        self.vocabularyField = vocabularyField

        let locale = NSPopUpButton()
        locale.addItem(withTitle: "Loading locales…")
        locale.isEnabled = false
        locale.target = self
        locale.action = #selector(localeChanged)
        locale.setAccessibilityLabel("Apple Speech conversation locale")
        locale.identifier = NSUserInterfaceItemIdentifier("transcription-locale")
        localePopup = locale
        let localeRow = SettingsRowView(
            title: "Conversation locale",
            detail: "One locale for the whole session",
            controlView: locale)
        content.addSubview(localeRow)
        self.localeRow = localeRow

        if preferences.provider == .appleSpeech {
            loadAppleSpeechLocales()
        }
        applyState()
        return card
    }

    private func applyState() {
        let usesOpenAI = preferences.provider == .openAI
        modelRow?.isHidden = !usesOpenAI
        languagesRow?.isHidden = !usesOpenAI
        vocabularyRow?.isHidden = !usesOpenAI
        localeRow?.isHidden = usesOpenAI
        refreshLanguageDetail()
        refreshVocabularyDetail()
        card?.frame.size.height = preferredHeight
        layoutRows()
        onHeightChanged?(preferredHeight)
    }

    private func refreshLanguageDetail() {
        let gpt4oIgnoresSelection = preferences.openAIModel == .gpt4oTranscribe
            && preferences.openAIExpectedLanguages.count > 1
        languagesRow?.setDetail(gpt4oIgnoresSelection
            ? "GPT-4o treats multiple selections as Automatic"
            : "No selection means Automatic")
    }

    private func refreshVocabularyDetail() {
        vocabularyRow?.setDetail(preferences.openAIModel == .gpt4oTranscribe
            ? "GPT-4o Transcribe ignores this — switch Model to use it"
            : "Comma-separated jargon and names bias recognition")
    }

    private func layoutRows() {
        guard let card else { return }
        let rows = [providerRow, preferences.provider == .openAI ? modelRow : localeRow,
                    preferences.provider == .openAI ? languagesRow : nil,
                    preferences.provider == .openAI ? vocabularyRow : nil].compactMap { $0 }
        var top = card.bodyFrame.maxY
        for row in rows {
            top -= row.preferredHeight
            row.frame = NSRect(
                x: 0,
                y: top,
                width: card.bodyFrame.width,
                height: row.preferredHeight)
        }
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
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let model = OpenAITranscriptionModel(rawValue: raw) else {
            return
        }
        preferences.openAIModel = model
        refreshLanguageDetail()
        refreshVocabularyDetail()
        jlog("Jarvis: \(model.displayName) selected for the next Start.")
    }

    func vocabularyChanged(_ rawValue: String) {
        let keywords = rawValue.split(separator: ",").map(String.init)
        preferences.openAIVocabularyKeywords = keywords
        vocabularyField?.stringValue = preferences.openAIVocabularyKeywords.joined(separator: ", ")
        jlog("Jarvis: \(preferences.openAIVocabularyKeywords.count) transcription vocabulary "
            + "term(s) selected for the next Start.")
    }

    private func languagesChanged(_ languages: [OpenAITranscriptionLanguage]) {
        preferences.openAIExpectedLanguages = languages
        refreshLanguageDetail()
        let selection = languages.isEmpty
            ? "automatic"
            : languages.map(\.displayName).joined(separator: ", ")
        jlog("Jarvis: \(selection) transcription languages selected for the next Start.")
    }

    @objc private func localeChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.selectedItem?.representedObject as? String else { return }
        preferences.appleSpeechLocaleIdentifier = identifier
        jlog("Jarvis: Apple Speech locale \(identifier) selected for the next Start.")
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
            let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: preferred)
            guard !Task.isCancelled, let self else { return }
            populateAppleSpeechLocales(locales, selectedIdentifier: equivalent?.identifier)
        }
        #else
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
            Self.localeTitle($0).localizedCaseInsensitiveCompare(Self.localeTitle($1))
                == .orderedAscending
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
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private static var appleSpeechIsAvailable: Bool {
        #if compiler(>=6.2) && canImport(FoundationModels) && canImport(Speech) && !JARVIS_FORCE_APPLE_SPEECH_FALLBACK
        if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
        #else
        return false
        #endif
    }
}
