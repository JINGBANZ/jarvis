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
    private var geminiModelRow: SettingsRowView?
    private var geminiLanguagesRow: SettingsRowView?
    private var geminiVocabularyRow: SettingsRowView?
    var geminiVocabularyField: NSTextField?
    private var geminiModeRow: SettingsRowView?
    private var localeRow: SettingsRowView?
    private var localePopup: NSPopUpButton?
    private var localeLoadTask: Task<Void, Never>?

    /// The rows one provider shows, top to bottom. The provider row is always first. Read before
    /// `makeView` runs (rows are still nil), so `compactMap` naturally yields the header-only list.
    private var visibleRows: [SettingsRowView] {
        switch preferences.provider {
        case .openAI:
            [providerRow, modelRow, languagesRow, vocabularyRow].compactMap { $0 }
        case .gemini:
            [providerRow, geminiModelRow, geminiLanguagesRow,
             geminiVocabularyRow, geminiModeRow].compactMap { $0 }
        case .appleSpeech:
            [providerRow, localeRow].compactMap { $0 }
        }
    }

    var preferredHeight: CGFloat {
        SettingsStyle.cardHeaderHeight + CGFloat(visibleRows.count) * SettingsStyle.rowHeight
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
        vocabularyField.placeholderString = "e.g. Kubernetes, gRPC, Ada Lovelace"
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

        let geminiModel = NSPopUpButton()
        for choice in GeminiTranscriptionModel.allCases {
            geminiModel.addItem(withTitle: choice.displayName)
            geminiModel.lastItem?.representedObject = choice.rawValue
        }
        if let selected = geminiModel.itemArray.firstIndex(where: {
            $0.representedObject as? String == preferences.geminiModel.rawValue
        }) {
            geminiModel.selectItem(at: selected)
        }
        geminiModel.target = self
        geminiModel.action = #selector(geminiModelChanged)
        geminiModel.setAccessibilityLabel("Gemini transcription model")
        geminiModel.identifier = NSUserInterfaceItemIdentifier("transcription-gemini-model")
        let geminiModelRow = SettingsRowView(
            title: "Model",
            detail: "Speech-to-text model",
            controlView: geminiModel)
        content.addSubview(geminiModelRow)
        self.geminiModelRow = geminiModelRow

        let geminiLanguagePicker = ExpectedLanguagePicker(
            selectedLanguages: preferences.geminiExpectedLanguages,
            onChange: { [weak self] languages in self?.geminiLanguagesChanged(languages) })
        geminiLanguagePicker.identifier =
            NSUserInterfaceItemIdentifier("transcription-gemini-languages")
        let geminiLanguagesRow = SettingsRowView(
            title: "Expected languages",
            detail: "No selection means automatic",
            controlView: geminiLanguagePicker,
            controlSize: NSSize(width: 340, height: 32))
        content.addSubview(geminiLanguagesRow)
        self.geminiLanguagesRow = geminiLanguagesRow

        let geminiVocabularyField = NSTextField()
        geminiVocabularyField.placeholderString = "e.g. Kubernetes, gRPC, Ada Lovelace"
        geminiVocabularyField.stringValue =
            preferences.geminiVocabularyKeywords.joined(separator: ", ")
        geminiVocabularyField.delegate = self
        geminiVocabularyField.setAccessibilityLabel("Gemini transcription vocabulary")
        geminiVocabularyField.identifier =
            NSUserInterfaceItemIdentifier("transcription-gemini-vocabulary")
        let geminiVocabularyRow = SettingsRowView(
            title: "Vocabulary",
            detail: "Comma-separated jargon and names bias recognition",
            controlView: geminiVocabularyField,
            controlSize: NSSize(width: 340, height: 24))
        content.addSubview(geminiVocabularyRow)
        self.geminiVocabularyRow = geminiVocabularyRow
        self.geminiVocabularyField = geminiVocabularyField

        let geminiMode = NSPopUpButton()
        for choice in GeminiTranscriptionMode.allCases {
            geminiMode.addItem(withTitle: choice.displayName)
            geminiMode.lastItem?.representedObject = choice.rawValue
        }
        if let selected = geminiMode.itemArray.firstIndex(where: {
            $0.representedObject as? String == preferences.geminiMode.rawValue
        }) {
            geminiMode.selectItem(at: selected)
        }
        geminiMode.target = self
        geminiMode.action = #selector(geminiModeChanged)
        geminiMode.setAccessibilityLabel("Gemini transcription mode")
        geminiMode.identifier = NSUserInterfaceItemIdentifier("transcription-gemini-mode")
        let geminiModeRow = SettingsRowView(
            title: "Mode",
            detail: "Smart removes filler words",
            controlView: geminiMode)
        content.addSubview(geminiModeRow)
        self.geminiModeRow = geminiModeRow

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
        let visible = Set(visibleRows.map(ObjectIdentifier.init))
        for row in [modelRow, languagesRow, vocabularyRow,
                    geminiModelRow, geminiLanguagesRow, geminiVocabularyRow, geminiModeRow,
                    localeRow] {
            row?.isHidden = row.map { !visible.contains(ObjectIdentifier($0)) } ?? true
        }
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
        let rows = visibleRows
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

    private func languagesChanged(_ languages: [TranscriptionLanguage]) {
        preferences.openAIExpectedLanguages = languages
        refreshLanguageDetail()
        let selection = languages.isEmpty
            ? "automatic"
            : languages.map(\.displayName).joined(separator: ", ")
        jlog("Jarvis: \(selection) transcription languages selected for the next Start.")
    }

    @objc private func geminiModelChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let model = GeminiTranscriptionModel(rawValue: raw) else {
            return
        }
        preferences.geminiModel = model
        jlog("Jarvis: \(model.displayName) selected for the next Start.")
    }

    func geminiVocabularyChanged(_ rawValue: String) {
        let keywords = rawValue.split(separator: ",").map(String.init)
        preferences.geminiVocabularyKeywords = keywords
        geminiVocabularyField?.stringValue =
            preferences.geminiVocabularyKeywords.joined(separator: ", ")
        jlog("Jarvis: \(preferences.geminiVocabularyKeywords.count) transcription vocabulary "
            + "term(s) selected for the next Start.")
    }

    private func geminiLanguagesChanged(_ languages: [TranscriptionLanguage]) {
        preferences.geminiExpectedLanguages = languages
        let selection = languages.isEmpty
            ? "automatic"
            : languages.map(\.displayName).joined(separator: ", ")
        jlog("Jarvis: \(selection) transcription languages selected for the next Start.")
    }

    @objc private func geminiModeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let mode = GeminiTranscriptionMode(rawValue: raw) else {
            return
        }
        preferences.geminiMode = mode
        jlog("Jarvis: \(mode.displayName) selected for the next Start.")
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
