import Foundation

/// Brain client over the OpenAI **Responses API** (`POST /v1/responses`) — the recommended
/// endpoint for tool use with gpt-5.5. System text is passed via `instructions`; the conversation
/// is sent as typed `input` items; function calls are threaded with `function_call` /
/// `function_call_output`. Includes bounded retry-with-backoff on 429/5xx (honoring `Retry-After`)
/// and a request timeout. Uses `store:true` + a per-session `conversation` for multi-turn continuity
/// (this DOES retain transcripts/screenshots server-side — a documented quality-first choice; see
/// wiki/sandbox.md).
public struct OpenAIBrainClient: BrainClient, @unchecked Sendable {
    /// Injected transport; returns the body and the HTTP response (for status + headers).
    public typealias Sender = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse?)

    private let apiKey: String
    private let model: String
    private let reasoningEffort: String
    private let endpoint: URL
    private let timeout: TimeInterval
    private let maxRetries: Int
    private let backoffBaseSeconds: Double
    private let maxOutputTokens: Int
    private let promptCacheKey: String
    private let send: Sender

    public init(apiKey: String,
                model: String,
                reasoningEffort: String = "low",
                endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
                timeout: TimeInterval = 15,
                maxRetries: Int = 2,
                backoffBaseSeconds: Double = 0.5,
                maxOutputTokens: Int = 768,   // headroom so reasoning + a short tool call don't truncate
                promptCacheKey: String = "jarvis-coach-v1",
                send: Sender? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.endpoint = endpoint
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.backoffBaseSeconds = backoffBaseSeconds
        self.maxOutputTokens = maxOutputTokens
        self.promptCacheKey = promptCacheKey
        self.send = send ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as? HTTPURLResponse)
        }
    }

    public func respond(messages: [ChatMessage], tools: [ToolDef],
                        toolChoice: ToolChoice, conversationId: String?) async throws -> BrainResponse {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encodeBody(messages: messages, tools: tools, toolChoice: toolChoice,
                                          conversationId: conversationId)

        var attempt = 0
        while true {
            let (data, http) = try await send(request)
            let status = http?.statusCode ?? 0
            if (200..<300).contains(status) { return try decode(data) }

            let retryable = status == 429 || (500...599).contains(status)
            if retryable && attempt < maxRetries {
                let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
                // Exponential backoff with multiplicative jitter; honor Retry-After when present.
                let backoff = backoffBaseSeconds * pow(2, Double(attempt)) * Double.random(in: 1.0...1.3)
                let delay = max(0, retryAfter ?? backoff)
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                attempt += 1
                continue
            }
            throw NSError(domain: "OpenAIBrainClient", code: status,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "http \(status)"])
        }
    }

    /// Create a server-side conversation (one per coaching session) so the model keeps continuity —
    /// including its own prior replies — across triggers. Returns the `conv_…` id.
    public func createConversation() async throws -> String {
        let url = URL(string: endpoint.absoluteString.replacingOccurrences(of: "/responses", with: "/conversations")) ?? endpoint
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        let (data, http) = try await send(request)
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "OpenAIBrainClient", code: status,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "http \(status)"])
        }
        struct Conversation: Decodable { let id: String }
        return try JSONDecoder().decode(Conversation.self, from: data).id
    }

    // MARK: - Encoding (Responses API)

    private func encodeBody(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice,
                            conversationId: String?) throws -> Data {
        var instructions: [String] = []
        var input: [[String: Any]] = []

        for m in messages {
            switch m.role {
            case .system:
                if let t = m.text { instructions.append(t) }

            case .user:
                if let img = m.imageBase64JPEG {
                    input.append([
                        "role": "user",
                        "content": [["type": "input_image",
                                     "image_url": "data:image/jpeg;base64,\(img)"]],
                    ])
                } else {
                    input.append([
                        "role": "user",
                        "content": [["type": "input_text", "text": m.text ?? ""]],
                    ])
                }

            case .assistant:
                // Replay the model's function calls as `function_call` input items (the tool loop).
                if let calls = m.toolCalls {
                    for c in calls {
                        input.append([
                            "type": "function_call",
                            "call_id": c.id,
                            "name": c.name,
                            "arguments": c.argumentsJSON,
                        ])
                    }
                } else if let t = m.text {
                    input.append(["role": "assistant",
                                  "content": [["type": "output_text", "text": t]]])
                }

            case .tool:
                input.append([
                    "type": "function_call_output",
                    "call_id": m.toolCallId ?? "",
                    "output": m.text ?? "",
                ])
            }
        }

        let toolsJSON: [[String: Any]] = try tools.map { t in
            let params = try JSONSerialization.jsonObject(with: Data(t.parametersJSON.utf8))
            // Responses API uses a FLAT function tool shape (no nested "function"). `strict:true`
            // turns on Structured Outputs for the call's arguments — the model is constrained to the
            // schema, so e.g. `speak`'s `lines` always decodes as an array of strings (no splitting
            // client-side). Strict requires every object in `parameters` to set
            // additionalProperties:false and list all its keys as required (see ToolDefs).
            return ["type": "function", "name": t.name, "description": t.description,
                    "parameters": params, "strict": true]
        }

        // Responses tool_choice: the string "auto", or a {type:function,name} object to force one.
        let toolChoiceJSON: Any
        switch toolChoice {
        case .auto: toolChoiceJSON = "auto"
        case .force(let name): toolChoiceJSON = ["type": "function", "name": name]
        }

        var body: [String: Any] = [
            "model": model,
            "input": input,
            "tools": toolsJSON,
            "tool_choice": toolChoiceJSON,
            "parallel_tool_calls": false,      // the coach loop consumes one tool call per turn
            "reasoning": ["effort": reasoningEffort],
            "max_output_tokens": maxOutputTokens,
            // store:true is required for server-side conversation continuity (the model remembers
            // prior turns, its own replies included). This DOES retain transcripts/screenshots
            // server-side — a deliberate quality-over-retention choice; see wiki/sandbox.md.
            "store": true,
            "prompt_cache_key": promptCacheKey, // stable system prompt → better cache routing
        ]
        if let conversationId {
            body["conversation"] = conversationId
        }
        if !instructions.isEmpty {
            body["instructions"] = instructions.joined(separator: "\n\n")
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Decoding (Responses API)

    private struct Response: Decodable {
        struct Item: Decodable {
            let type: String
            let call_id: String?
            let name: String?
            let arguments: String?
        }
        struct IncompleteDetails: Decodable { let reason: String? }
        let output: [Item]
        let status: String?
        let incomplete_details: IncompleteDetails?
    }

    private func decode(_ data: Data) throws -> BrainResponse {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        var invocations: [ToolInvocation] = []
        var raws: [RawToolCall] = []
        for item in decoded.output where item.type == "function_call" {
            guard let callId = item.call_id, let name = item.name else { continue }
            let args = item.arguments ?? "{}"
            raws.append(RawToolCall(id: callId, name: name, argumentsJSON: args))
            switch name {
            case "capture_screen":
                invocations.append(.captureScreen(callId: callId))
            case "speak":
                // `strict:true` guarantees the shape: { "lines": [string, …] }. Decode it directly —
                // the model already split the tip into overlay lines, so there's nothing to split here.
                let lines = (try? JSONDecoder().decode([String: [String]].self,
                                                       from: Data(args.utf8)))?["lines"] ?? []
                invocations.append(.speak(callId: callId, lines: lines))
            default:
                jlog("Jarvis coach: ignoring unknown tool '\(name)'")
            }
        }
        // A truncated run (`status:"incomplete"`, e.g. reasoning+output exceeding max_output_tokens)
        // can carry zero tool calls — surface the reason so the coach loop doesn't mistake it for
        // a deliberate stay-silent. Prefer the explicit reason; fall back to "incomplete".
        let incompleteReason = decoded.status == "incomplete"
            ? (decoded.incomplete_details?.reason ?? "incomplete")
            : nil
        return BrainResponse(toolCalls: invocations, rawToolCalls: raws, incompleteReason: incompleteReason)
    }
}
