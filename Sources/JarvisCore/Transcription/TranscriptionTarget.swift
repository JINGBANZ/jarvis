import Foundation

public enum TranscriptionTarget: Codable, Equatable, Sendable {
    case openAI(OpenAITranscriptionModel)
    case gemini(GeminiTranscriptionModel)
    case deepgram(DeepgramTranscriptionModel)
    case appleSpeech(localeIdentifier: String)

    public enum LanguageSupport: Equatable, Sendable {
        case singularHintAndContext
        case languageList
        case singleLocale
    }

    public var provider: TranscriptionProvider {
        switch self {
        case .openAI: .openAI
        case .gemini: .gemini
        case .deepgram: .deepgram
        case .appleSpeech: .appleSpeech
        }
    }

    public var modelID: String? {
        switch self {
        case .openAI(let model): model.rawValue
        case .gemini(let model): model.rawValue
        case .deepgram(let model): model.rawValue
        case .appleSpeech: nil
        }
    }

    public var localeIdentifier: String? {
        if case .appleSpeech(let locale) = self { return locale }
        return nil
    }

    public var languageSupport: LanguageSupport {
        switch self {
        case .openAI(.gpt4oTranscribe): .singularHintAndContext
        case .openAI(.gptTranscribe), .openAI(.gptLiveTranscribe), .gemini(.geminiTranscribeLive): .languageList
        case .deepgram: .singularHintAndContext
        case .appleSpeech: .singleLocale
        }
    }

    public var confirmation: TranscriptionSetupAcceptance.Confirmation {
        switch self {
        case .openAI: .effectiveConfiguration
        case .gemini: .setupAcknowledged
        case .deepgram: .connectionOpened
        case .appleSpeech: .localPreparation
        }
    }

    public static var remoteTargets: [TranscriptionTarget] {
        TranscriptionProvider.allCases.flatMap { provider -> [TranscriptionTarget] in
            switch provider {
            case .openAI: OpenAITranscriptionModel.allCases.map(Self.openAI)
            case .gemini: GeminiTranscriptionModel.allCases.map(Self.gemini)
            // One language per stream sits outside the language contract and the benchmark arms.
            case .deepgram: []
            case .appleSpeech: []
            }
        }
    }

    public func context(
        for speaker: Speaker,
        expectation: TranscriptionLanguageExpectation
    ) -> String? {
        switch self {
        case .openAI(.gpt4oTranscribe):
            guard expectation.languages.count > 1 else { return nil }
            return JarvisPrompts.Transcription.context(for: speaker)
                + " " + JarvisPrompts.Transcription.languageContext(expectation.languages)
        case .openAI(.gptTranscribe), .openAI(.gptLiveTranscribe):
            return JarvisPrompts.Transcription.context(for: speaker)
        case .gemini(.geminiTranscribeLive), .deepgram(.nova3), .appleSpeech:
            return nil
        }
    }

    public func configuration(
        expectedLanguages: [TranscriptionLanguage]
    ) -> TranscriptionConfiguration {
        switch self {
        case .openAI(let model):
            return TranscriptionConfiguration(provider: .openAI, openAIModel: model,
                openAIExpectedLanguages: expectedLanguages, appleSpeechLocaleIdentifier: "en_US")
        case .gemini(let model):
            return TranscriptionConfiguration(provider: .gemini, openAIModel: .gpt4oTranscribe,
                openAIExpectedLanguages: [], appleSpeechLocaleIdentifier: "en_US",
                geminiModel: model, geminiExpectedLanguages: expectedLanguages)
        case .deepgram(let model):
            return TranscriptionConfiguration(provider: .deepgram, openAIModel: .gpt4oTranscribe,
                openAIExpectedLanguages: [], appleSpeechLocaleIdentifier: "en_US",
                deepgramModel: model, deepgramLanguage: expectedLanguages.first ?? .english)
        case .appleSpeech(let locale):
            precondition(expectedLanguages.isEmpty, "Apple Speech uses its selected locale")
            return TranscriptionConfiguration(provider: .appleSpeech, openAIModel: .gpt4oTranscribe,
                openAIExpectedLanguages: [], appleSpeechLocaleIdentifier: locale)
        }
    }
}
