import Foundation

/// Adding a provider is one `BrainProvider` case plus one of these; nothing outside it asks which
/// provider it holds. See wiki/architecture.md.
public struct BrainProviderDescriptor: Sendable, Equatable {
    public enum Access: Sendable, Equatable {
        case apiKey(credential: Credential, endpoint: URL, auth: AuthScheme)
        /// `modelOwner` is the `owned_by` value in the helper's model list that proves the sign-in.
        case localProxy(modelOwner: String, loginFlag: String, accountFilePrefix: String)
    }

    public enum AuthScheme: Sendable, Equatable {
        case bearer
        case googAPIKey
    }

    public enum WireFormat: Sendable, Equatable {
        case responses
        case interactions
    }

    public enum FailureTable: Sendable, Equatable {
        case openAI
        case gemini
    }

    public static let openAIResponsesEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    // The stable version; the probe found it identical to v1beta.
    public static let geminiInteractionsEndpoint =
        URL(string: "https://generativelanguage.googleapis.com/v1/interactions")!

    public let displayName: String
    public let access: Access
    public let wire: WireFormat
    public let failureTable: FailureTable
    public let toolChoicePolicy: ToolChoicePolicy
    /// Applied without rewriting the saved preference; a model's own floor is catalog data.
    public let reasoningEffortFloor: ReasoningEffort?

    public var credential: Credential? {
        if case .apiKey(let credential, _, _) = access { credential } else { nil }
    }

    public var servedByLocalProxy: Bool {
        if case .localProxy = access { true } else { false }
    }

    /// The helper's per-launch key is a bearer token too.
    public var auth: AuthScheme {
        if case .apiKey(_, _, let auth) = access { auth } else { .bearer }
    }
}
