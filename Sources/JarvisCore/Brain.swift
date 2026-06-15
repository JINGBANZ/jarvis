import Foundation

/// A tool call exactly as the model emitted it — needed to replay the assistant turn back
/// into the conversation (the Chat Completions API requires the assistant `tool_calls` message
/// to precede any `tool` result message).
public struct RawToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// A message in the brain conversation. Minimal, provider-agnostic; the real client maps it.
public struct ChatMessage: Sendable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public let role: Role
    public let text: String?
    /// Base64-encoded JPEG, for feeding a screenshot back to a vision model (user role).
    public let imageBase64JPEG: String?
    /// For tool-result messages: which tool call this answers.
    public let toolCallId: String?
    /// For assistant messages that made tool calls: the calls to replay.
    public let toolCalls: [RawToolCall]?

    public init(role: Role, text: String? = nil, imageBase64JPEG: String? = nil,
                toolCallId: String? = nil, toolCalls: [RawToolCall]? = nil) {
        self.role = role
        self.text = text
        self.imageBase64JPEG = imageBase64JPEG
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
    }

    public static func system(_ t: String) -> ChatMessage { .init(role: .system, text: t) }
    public static func user(_ t: String) -> ChatMessage { .init(role: .user, text: t) }
    public static func userImage(_ base64JPEG: String) -> ChatMessage { .init(role: .user, imageBase64JPEG: base64JPEG) }
    public static func assistantToolCalls(_ calls: [RawToolCall]) -> ChatMessage { .init(role: .assistant, toolCalls: calls) }
}

/// A tool definition exposed to the model.
public struct ToolDef: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for parameters, as a JSON string.
    public let parametersJSON: String
    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// A tool call the model wants the harness to perform.
public enum ToolInvocation: Sendable, Equatable {
    case captureScreen(callId: String)
    case speak(callId: String, text: String)
}

/// One brain response: parsed tool calls (possibly empty = stay silent), plus the raw calls
/// needed to replay the assistant turn during the tool loop.
public struct BrainResponse: Sendable {
    public let toolCalls: [ToolInvocation]
    public let rawToolCalls: [RawToolCall]
    /// Non-nil when the model run did NOT finish cleanly (Responses `status:"incomplete"`), carrying
    /// the reason (e.g. `"max_output_tokens"`). An empty `toolCalls` with a non-nil reason is
    /// *truncation*, not a deliberate decision to stay silent — the coach loop distinguishes them.
    public let incompleteReason: String?
    public init(toolCalls: [ToolInvocation], rawToolCalls: [RawToolCall] = [],
                incompleteReason: String? = nil) {
        self.toolCalls = toolCalls
        self.rawToolCalls = rawToolCalls
        self.incompleteReason = incompleteReason
    }
}

/// How the model may use tools on a given turn. `auto` lets it call zero, one, or many (the
/// silence-by-default coaching default); `force(name)` requires it to call exactly that function
/// (used to GUARANTEE a reply on a direct address — a bare "required" would let it satisfy the
/// constraint by calling capture_screen and looping instead of speaking).
public enum ToolChoice: Sendable, Equatable {
    case auto
    case force(String)
}

/// Abstraction over the brain model so CoachDriver is testable with a mock.
public protocol BrainClient: Sendable {
    /// `conversationId`, when non-nil, ties this turn into a server-side conversation so the model
    /// remembers prior turns (its own replies included) without re-sending them — the caller sends
    /// only the NEW input each turn.
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice,
                 conversationId: String?) async throws -> BrainResponse
    /// Create a server-side conversation and return its id. Default: a local stub (no server state),
    /// so mocks/tests need not implement it.
    func createConversation() async throws -> String
}

public extension BrainClient {
    func createConversation() async throws -> String { "conv_local" }

    /// Convenience overloads so callers/tests need not pass every argument.
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        try await respond(messages: messages, tools: tools, toolChoice: toolChoice, conversationId: nil)
    }
    func respond(messages: [ChatMessage], tools: [ToolDef]) async throws -> BrainResponse {
        try await respond(messages: messages, tools: tools, toolChoice: .auto, conversationId: nil)
    }
}
