import Foundation

public enum TranscriptionProvider: String, CaseIterable, Codable, Sendable {
    case openAI = "openai"
    case appleSpeech = "apple-speech"
    case gemini = "gemini"

    public var displayName: String {
        switch self {
        case .openAI:
            "OpenAI"
        case .appleSpeech:
            "Apple Speech"
        case .gemini:
            "Gemini"
        }
    }

    public var ownCredential: Credential? {
        switch self {
        case .openAI: .openAIAPIKey
        case .gemini: .geminiAPIKey
        case .appleSpeech: nil
        }
    }

    public func requiredCredentials(for brainRoute: BrainRoute?) -> Set<Credential> {
        var required = Set(ownCredential.map { [$0] } ?? [])
        if brainRoute?.targets.contains(where: { $0.provider == .openAI }) == true {
            required.insert(.openAIAPIKey)
        }
        return required
    }

    public var audioFormat: TranscriptionAudioFormat {
        switch self {
        case .openAI, .appleSpeech: .pcm16Mono24k
        case .gemini: .pcm16Mono16k
        }
    }
}
