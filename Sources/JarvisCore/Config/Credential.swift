import Foundation

/// One API credential Jarvis stores on the user's behalf.
///
/// Raw values are stable identity, never user-facing copy: they key the readiness gate's required/
/// available sets and name the owner-only file each credential lives in.
public enum Credential: String, Sendable, Hashable, CaseIterable {
    case openAIAPIKey
    case geminiAPIKey

    /// Filename inside the shared Application Support directory. Kept lowercase-hyphenated so the
    /// existing `openai-api-key` file keeps working without a migration.
    public var fileName: String {
        switch self {
        case .openAIAPIKey: "openai-api-key"
        case .geminiAPIKey: "gemini-api-key"
        }
    }

    /// Headless fallback source, read only when the file is absent.
    public var environmentVariable: String {
        switch self {
        case .openAIAPIKey: "OPENAI_API_KEY"
        case .geminiAPIKey: "GEMINI_API_KEY"
        }
    }

    /// Card title in Connections Settings.
    public var displayName: String {
        switch self {
        case .openAIAPIKey: "OpenAI API"
        case .geminiAPIKey: "Gemini API"
        }
    }

    /// The vendor alone, for a sentence that already names the key ("OpenAI refused the key"), where
    /// `displayName`'s "API" suffix would read as part of the claim.
    public var vendorName: String {
        switch self {
        case .openAIAPIKey: "OpenAI"
        case .geminiAPIKey: "Gemini"
        }
    }

    /// Placeholder shown in the empty key-entry field, shaped like a real key from this provider so
    /// the field doesn't show OpenAI's `sk-…` shape on every credential card.
    public var placeholderHint: String {
        switch self {
        case .openAIAPIKey: "sk-…"
        case .geminiAPIKey: "AIza…"
        }
    }
}
