import Foundation

/// Raw values are stable identity, never user-facing copy.
public enum Credential: String, Sendable, Hashable, CaseIterable {
    case openAIAPIKey
    case geminiAPIKey
    case deepgramAPIKey

    /// Persisted file names. Renaming one orphans a saved key.
    public var fileName: String {
        switch self {
        case .openAIAPIKey: "openai-api-key"
        case .geminiAPIKey: "gemini-api-key"
        case .deepgramAPIKey: "deepgram-api-key"
        }
    }

    public var environmentVariable: String {
        switch self {
        case .openAIAPIKey: "OPENAI_API_KEY"
        case .geminiAPIKey: "GEMINI_API_KEY"
        case .deepgramAPIKey: "DEEPGRAM_API_KEY"
        }
    }

    public var displayName: String {
        switch self {
        case .openAIAPIKey: "OpenAI API"
        case .geminiAPIKey: "Gemini API"
        case .deepgramAPIKey: "Deepgram API"
        }
    }

    public var vendorName: String {
        switch self {
        case .openAIAPIKey: "OpenAI"
        case .geminiAPIKey: "Gemini"
        case .deepgramAPIKey: "Deepgram"
        }
    }

    /// What the key powers, for its Connections card.
    public var roles: String {
        switch self {
        case .openAIAPIKey, .geminiAPIKey: "Brain and transcription"
        case .deepgramAPIKey: "Transcription"
        }
    }

    public var placeholderHint: String {
        switch self {
        case .openAIAPIKey: "sk-…"
        case .geminiAPIKey: "AIza…"
        case .deepgramAPIKey: "Token…"
        }
    }

    /// Where a new user creates a key.
    public var keyPageURL: URL {
        switch self {
        case .openAIAPIKey: URL(string: "https://platform.openai.com/api-keys")!
        case .geminiAPIKey: URL(string: "https://aistudio.google.com/apikey")!
        case .deepgramAPIKey: URL(string: "https://console.deepgram.com/")!
        }
    }
}
