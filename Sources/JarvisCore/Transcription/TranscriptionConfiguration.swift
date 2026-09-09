import Foundation

/// Immutable transcription choices captured at Start and shared by both speaker endpoints.
///
/// Keeping one value for the provider-specific settings prevents a Settings edit or reconnect from
/// splitting the mic and system-audio streams across different models, hints, or Apple locales.
public struct TranscriptionConfiguration: Equatable, Sendable {
    public let provider: TranscriptionProvider
    public let openAIModel: OpenAITranscriptionModel
    public let openAIExpectedLanguages: [TranscriptionLanguage]
    public let openAIVocabularyKeywords: [String]
    public let appleSpeechLocaleIdentifier: String
    public let geminiModel: GeminiTranscriptionModel
    public let geminiExpectedLanguages: [TranscriptionLanguage]
    public let geminiVocabularyKeywords: [String]
    public let geminiMode: GeminiTranscriptionMode

    public init(
        provider: TranscriptionProvider,
        openAIModel: OpenAITranscriptionModel,
        openAIExpectedLanguages: [TranscriptionLanguage],
        openAIVocabularyKeywords: [String] = [],
        appleSpeechLocaleIdentifier: String,
        geminiModel: GeminiTranscriptionModel = .geminiTranscribeLive,
        geminiExpectedLanguages: [TranscriptionLanguage] = [],
        geminiVocabularyKeywords: [String] = [],
        geminiMode: GeminiTranscriptionMode = .verbatim
    ) {
        self.provider = provider
        self.openAIModel = openAIModel
        self.openAIExpectedLanguages = TranscriptionLanguage.canonicalizing(
            openAIExpectedLanguages)
        self.openAIVocabularyKeywords = openAIVocabularyKeywords
        self.appleSpeechLocaleIdentifier = appleSpeechLocaleIdentifier
        self.geminiModel = geminiModel
        self.geminiExpectedLanguages = TranscriptionLanguage.canonicalizing(geminiExpectedLanguages)
        self.geminiVocabularyKeywords = geminiVocabularyKeywords
        self.geminiMode = geminiMode
    }

    /// A single explicit language guides coaching replies; Automatic and multiple selections
    /// leave the reply language to the user's conversation. This never filters incoming speech.
    public var coachingReplyLanguage: String? {
        switch provider {
        case .openAI:
            return openAIExpectedLanguages.count == 1 ? openAIExpectedLanguages.first?.displayName : nil
        case .gemini:
            return geminiExpectedLanguages.count == 1 ? geminiExpectedLanguages.first?.displayName : nil
        case .appleSpeech:
            let locale = Locale(identifier: appleSpeechLocaleIdentifier)
            guard let code = locale.language.languageCode?.identifier else { return nil }
            return Locale(identifier: "en").localizedString(forLanguageCode: code)
        }
    }

    /// Apple owns result segmentation internally; OpenAI exposes an explicit turn strategy.
    public var turnDetectionStrategy: TranscriptionTurnDetectionStrategy? {
        provider == .openAI ? openAIModel.turnDetectionStrategy : nil
    }
}
