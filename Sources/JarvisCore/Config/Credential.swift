import Foundation

/// Raw values are stable identity, never user-facing copy.
public enum Credential: String, Sendable, Hashable, CaseIterable {
    case openAIAPIKey
    case geminiAPIKey

    /// Persisted file names. Renaming one orphans a saved key.
    public var fileName: String {
        switch self {
        case .openAIAPIKey: "openai-api-key"
        case .geminiAPIKey: "gemini-api-key"
        }
    }

    public var environmentVariable: String {
        switch self {
        case .openAIAPIKey: "OPENAI_API_KEY"
        case .geminiAPIKey: "GEMINI_API_KEY"
        }
    }

    public var displayName: String {
        switch self {
        case .openAIAPIKey: "OpenAI API"
        case .geminiAPIKey: "Gemini API"
        }
    }

    public var vendorName: String {
        switch self {
        case .openAIAPIKey: "OpenAI"
        case .geminiAPIKey: "Gemini"
        }
    }

    public var placeholderHint: String {
        switch self {
        case .openAIAPIKey: "sk-…"
        case .geminiAPIKey: "AIza…"
        }
    }

    /// Where a new user creates a key.
    public var keyPageURL: URL {
        switch self {
        case .openAIAPIKey: URL(string: "https://platform.openai.com/api-keys")!
        case .geminiAPIKey: URL(string: "https://aistudio.google.com/apikey")!
        }
    }
}
