import Foundation

/// Captured once at Start, so a Settings edit or reconnect can't split the two speaker streams
/// across different models, hints, or locales.
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

    /// Nil for providers that segment turns themselves.
    public var turnDetectionStrategy: TranscriptionTurnDetectionStrategy? {
        provider == .openAI ? openAIModel.turnDetectionStrategy : nil
    }

    public var target: TranscriptionTarget {
        switch provider {
        case .openAI: .openAI(openAIModel)
        case .gemini: .gemini(geminiModel)
        case .appleSpeech: .appleSpeech(localeIdentifier: appleSpeechLocaleIdentifier)
        }
    }

    public var languageExpectation: TranscriptionLanguageExpectation {
        switch provider {
        case .openAI: .init(languages: openAIExpectedLanguages)
        case .gemini: .init(languages: geminiExpectedLanguages)
        case .appleSpeech: .locale(appleSpeechLocaleIdentifier)
        }
    }
}
