import Foundation

/// Immutable transcription choices captured at Start and shared by both speaker endpoints.
///
/// Keeping one value for the provider-specific settings prevents a Settings edit or reconnect from
/// splitting the mic and system-audio streams across different models, hints, or Apple locales.
public struct TranscriptionConfiguration: Equatable, Sendable {
    public let provider: TranscriptionProvider
    public let openAIModel: OpenAITranscriptionModel
    public let openAIExpectedLanguages: [OpenAITranscriptionLanguage]
    public let openAIVocabularyKeywords: [String]
    public let appleSpeechLocaleIdentifier: String

    public init(
        provider: TranscriptionProvider,
        openAIModel: OpenAITranscriptionModel,
        openAIExpectedLanguages: [OpenAITranscriptionLanguage],
        openAIVocabularyKeywords: [String] = [],
        appleSpeechLocaleIdentifier: String
    ) {
        self.provider = provider
        self.openAIModel = openAIModel
        self.openAIExpectedLanguages = OpenAITranscriptionLanguage.canonicalizing(
            openAIExpectedLanguages)
        self.openAIVocabularyKeywords = openAIVocabularyKeywords
        self.appleSpeechLocaleIdentifier = appleSpeechLocaleIdentifier
    }

    /// A single explicit language guides coaching replies; Automatic and multiple selections
    /// leave the reply language to the user's conversation. This never filters incoming speech.
    public var coachingReplyLanguage: String? {
        switch provider {
        case .openAI:
            return openAIExpectedLanguages.count == 1 ? openAIExpectedLanguages.first?.displayName : nil
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
