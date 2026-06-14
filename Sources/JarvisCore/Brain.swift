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
    public init(toolCalls: [ToolInvocation], rawToolCalls: [RawToolCall] = []) {
        self.toolCalls = toolCalls
        self.rawToolCalls = rawToolCalls
    }
}

/// Abstraction over the brain model so CoachDriver is testable with a mock.
public protocol BrainClient: Sendable {
    func respond(messages: [ChatMessage], tools: [ToolDef]) async throws -> BrainResponse
}
