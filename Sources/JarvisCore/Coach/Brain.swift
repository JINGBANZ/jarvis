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
    /// Provider items replayed VERBATIM, one JSON object per string (a Responses `output` array:
    /// reasoning items, function_call items with their ids, …). The client re-emits them untouched:
    /// OpenAI requires a response's output items to ride along with the tool output, byte-for-byte
    /// and in order, or the reasoning/function-call linkage validation rejects the request.
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
    public static func rawItems(_ itemsJSON: [String]) -> ChatMessage { .init(role: .assistant, rawItemsJSON: itemsJSON) }
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
    /// The overlay lines to show, already split by the model (the `speak` tool's `lines` array) and
    /// rendered one at a time — so the client never splits a free-form string on punctuation.
    case speak(callId: String, lines: [String])
    /// The model's explicit "nothing useful to add" decision. Silence is a tool call (not the absence
    /// of one) so that `tool_choice: required` can forbid plain-text output entirely — free text from
    /// a stay-quiet turn used to be stored in the server-side conversation, where the model imitated
    /// its own leaked deliberation and degenerated (and every stored byte was re-billed every turn).
    case staySilent(callId: String)
}

/// One brain response: parsed tool calls (possibly empty = stay silent), plus the raw calls
/// needed to replay the assistant turn during the tool loop.
public struct BrainResponse: Sendable {
    public let toolCalls: [ToolInvocation]
    public let rawToolCalls: [RawToolCall]
    /// The response's ENTIRE `output` array, verbatim (one JSON object per string, in output
    /// order — reasoning, function_call, everything, ids intact). OpenAI's function-calling
    /// guidance: when a tool call is fulfilled client-side, replay the model's output items whole
    /// and unmodified with the tool output (`input.push(...response.output)`) — a reasoning item
    /// replayed next to a rebuilt, id-less function_call trips the provider's reasoning/function-call
    /// linkage validation, and dropping the reasoning makes the model re-reason from scratch. Only
    /// the within-turn tool loop needs this; `CoachHistory.commit` converts it before it reaches
    /// session memory.
    public let outputItemsJSON: [String]
    /// Non-nil when the model run did NOT finish cleanly (Responses `status:"incomplete"`), carrying
    /// the reason (e.g. `"max_output_tokens"`). An empty `toolCalls` with a non-nil reason is
    /// *truncation*, not a deliberate decision to stay silent — the coach loop distinguishes them.
    public let incompleteReason: String?
    /// The response's plain text output, if any. Coaching turns never use it (tool_choice is
    /// required there); it exists for tool-less calls like the history summarizer.
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

/// How the model may use tools on a given turn. `required` (some tool, model's pick) is what
/// audio-driven turns use: with `stay_silent` in the tool set every decision — nudge, look, or stay
/// quiet — is a clean tool call and the model never emits plain text into the stored conversation.
/// `force(name)` (require exactly that function) is used by the manual-hint hotkey, which forces
/// `speak` so an explicit ⌥⌘J keypress always yields a visible hint in one round trip (see
/// `CoachDriver.runTurn` + `TriggerReason.manualHint`). `auto` (zero or more calls) remains for tests
/// and future callers that genuinely want optional tool use.
public enum ToolChoice: Sendable, Equatable {
    case auto
    case required
    case force(String)
}

/// Abstraction over the brain model so CoachDriver is testable with a mock. Every call is
/// self-contained: the session's memory is CLIENT-managed (`CoachHistory`) and sent in `messages`,
/// so there is no server-side conversation object to create, thread, or lock.
public protocol BrainClient: Sendable {
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse
}

public extension BrainClient {
    /// Convenience overload so callers/tests need not pass every argument.
    func respond(messages: [ChatMessage], tools: [ToolDef]) async throws -> BrainResponse {
        try await respond(messages: messages, tools: tools, toolChoice: .auto)
    }
}
