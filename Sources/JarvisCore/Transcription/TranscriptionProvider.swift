import Foundation

public enum TranscriptionProvider: String, CaseIterable, Codable, Sendable {
    case openAI = "openai"
    case appleSpeech = "apple-speech"
    case gemini = "gemini"
    case deepgram = "deepgram"

    public var displayName: String {
        switch self {
        case .openAI:
            "OpenAI"
        case .appleSpeech:
            "Apple Speech"
        case .gemini:
            "Gemini"
        case .deepgram:
            "Deepgram"
        }
    }

    public var ownCredential: Credential? {
        switch self {
        case .openAI: .openAIAPIKey
        case .gemini: .geminiAPIKey
        case .deepgram: .deepgramAPIKey
        case .appleSpeech: nil
        }
    }

    public func requiredCredentials(for brainRoute: BrainRoute?) -> Set<Credential> {
        var required = brainRoute?.requiredCredentials ?? []
        if let ownCredential { required.insert(ownCredential) }
        return required
    }

    public var audioFormat: TranscriptionAudioFormat {
        switch self {
        case .openAI, .appleSpeech: .pcm16Mono24k
        case .gemini, .deepgram: .pcm16Mono16k
        }
    }
}
