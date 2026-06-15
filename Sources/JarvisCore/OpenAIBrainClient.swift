import Foundation

/// Brain client over the OpenAI **Responses API** (`POST /v1/responses`) — the recommended
/// endpoint for tool use with gpt-5.5. System text is passed via `instructions`; the conversation
/// is sent as typed `input` items; function calls are threaded with `function_call` /
/// `function_call_output`. Includes bounded retry-with-backoff on 429/5xx (honoring `Retry-After`),
/// a request timeout, and `store:false` so screenshots/transcripts aren't retained server-side.
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
                maxOutputTokens: Int = 400,
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
                        toolChoice: ToolChoice) async throws -> BrainResponse {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encodeBody(messages: messages, tools: tools, toolChoice: toolChoice)

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

    // MARK: - Encoding (Responses API)

    private func encodeBody(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) throws -> Data {
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
            // Responses API uses a FLAT function tool shape (no nested "function").
            return ["type": "function", "name": t.name, "description": t.description, "parameters": params]
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
            "store": false,                    // don't retain screenshots/transcripts server-side
            "prompt_cache_key": promptCacheKey, // stable system prompt → better cache routing
        ]
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
                let text = (try? JSONDecoder().decode([String: String].self,
                                                      from: Data(args.utf8)))?["text"] ?? ""
                invocations.append(.speak(callId: callId, text: text))
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
