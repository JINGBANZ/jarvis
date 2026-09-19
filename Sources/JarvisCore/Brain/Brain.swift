import Foundation

/// As the model emitted it: providers require the assistant call message before its tool result.
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

public struct ChatMessage: Sendable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public let role: Role
    public let text: String?
    public let imageBase64JPEG: String?
    public let toolCallId: String?
    public let toolCalls: [RawToolCall]?
    /// Re-emitted untouched, and nothing else for the message: OpenAI rejects output items not
    /// replayed byte-for-byte and in order. `CoachHistory.commit` drops them and keeps `toolCalls`.
    public let rawItemsJSON: [String]?

    public init(role: Role, text: String? = nil, imageBase64JPEG: String? = nil,
                toolCallId: String? = nil, toolCalls: [RawToolCall]? = nil,
                rawItemsJSON: [String]? = nil) {
        self.role = role
        self.text = text
        self.imageBase64JPEG = imageBase64JPEG
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
        self.rawItemsJSON = rawItemsJSON
    }

    public static func system(_ t: String) -> ChatMessage { .init(role: .system, text: t) }
    public static func user(_ t: String) -> ChatMessage { .init(role: .user, text: t) }
    public static func userImage(_ base64JPEG: String) -> ChatMessage { .init(role: .user, imageBase64JPEG: base64JPEG) }
    public static func assistantToolCalls(_ calls: [RawToolCall]) -> ChatMessage { .init(role: .assistant, toolCalls: calls) }
    public static func rawItems(_ itemsJSON: [String], calls: [RawToolCall]) -> ChatMessage {
        .init(role: .assistant, toolCalls: calls, rawItemsJSON: itemsJSON)
    }
}

public struct ToolDef: Sendable, Equatable {
    public let name: String
    public let description: String
    /// Strict Structured Outputs: every object sets `additionalProperties:false` and lists every
    /// key in `required`, so an optional field is nullable instead.
    public let parametersJSON: String
    /// In the system prompt for a hot tool, the `load_tool` result for a deferred one.
    public let guidance: String
    public let deferLoading: Bool
    public init(name: String, description: String, parametersJSON: String,
                guidance: String = "", deferLoading: Bool = false) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
        self.guidance = guidance
        self.deferLoading = deferLoading
    }
}

public enum ToolInvocation: Sendable, Equatable {
    case captureScreen(callId: String)
    /// `lines` arrive split by the model; the client never splits text on punctuation.
    case speak(callId: String, lines: [String], detail: String? = nil)
    /// A tool call, not an absence, so `tool_choice: required` can forbid plain-text replies.
    case staySilent(callId: String)
    case searchPrepNotes(callId: String, query: String)
    case loadTool(callId: String, name: String)
    case loadSkill(callId: String, name: String)
}

public struct BrainResponse: Sendable {
    public let toolCalls: [ToolInvocation]
    public let rawToolCalls: [RawToolCall]
    /// The reply's own output items verbatim (Responses `output`, Interactions `steps`). The tool
    /// loop replays them whole: providers reject rebuilt calls beside their reasoning.
    public let outputItemsJSON: [String]
    /// Non-nil (e.g. `"max_output_tokens"`) when the run did not finish; never trust its tool
    /// calls.
    public let incompleteReason: String?
    public let outputText: String?
    public init(toolCalls: [ToolInvocation], rawToolCalls: [RawToolCall] = [],
                incompleteReason: String? = nil, outputText: String? = nil,
                outputItemsJSON: [String] = []) {
        self.toolCalls = toolCalls
        self.rawToolCalls = rawToolCalls
        self.incompleteReason = incompleteReason
        self.outputText = outputText
        self.outputItemsJSON = outputItemsJSON
    }
}

/// `allowed` is `required` narrowed to the listed names while the declared tool array stays whole.
public enum ToolChoice: Sendable, Equatable {
    case auto
    case required
    case allowed([String])
    case force(String)
}

/// Owned by one attempt; provider-native state is never reused by another. Call `finish()` to
/// release any leased runtime.
public protocol BrainConversation: Sendable {
    func respond(messages: [ChatMessage], tools: [ToolDef],
                 toolChoice: ToolChoice) async throws -> BrainResponse
    func finish() async
}

public protocol BrainClient: Sendable {
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse
    /// `progress` hears every streamed tool-call delta of the conversation's requests; a client
    /// that reads replies whole never calls it.
    func makeConversation(progress: ToolCallProgressSink?) async throws -> any BrainConversation
    func prepare()
}

public extension BrainClient {
    func respond(messages: [ChatMessage], tools: [ToolDef]) async throws -> BrainResponse {
        try await respond(messages: messages, tools: tools, toolChoice: .auto)
    }

    func makeConversation(progress: ToolCallProgressSink?) async throws -> any BrainConversation {
        ForwardingBrainConversation(client: self)
    }

    func prepare() {}
}

private struct ForwardingBrainConversation: BrainConversation {
    let client: any BrainClient

    func respond(messages: [ChatMessage], tools: [ToolDef],
                 toolChoice: ToolChoice) async throws -> BrainResponse {
        try await client.respond(messages: messages, tools: tools, toolChoice: toolChoice)
    }

    func finish() async {}
}
