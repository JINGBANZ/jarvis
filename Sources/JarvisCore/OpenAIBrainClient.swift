import Foundation

/// Brain client over the OpenAI **Responses API** (`POST /v1/responses`) — the recommended
/// endpoint for tool use with gpt-5.5 (Chat Completions restricts tool calls under some reasoning
/// modes). System text is passed via `instructions`; the conversation is sent as typed `input`
/// items; function calls are threaded with `function_call` / `function_call_output`.
public struct OpenAIBrainClient: BrainClient, @unchecked Sendable {
    public typealias Sender = @Sendable (URLRequest) async throws -> (Data, Int)

    private let apiKey: String
    private let model: String
    private let reasoningEffort: String
    private let endpoint: URL
    private let send: Sender

    /// `send` defaults to URLSession; tests inject a stub returning (body, statusCode).
    public init(apiKey: String,
                model: String,
                reasoningEffort: String = "low",
                endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
                send: Sender? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.endpoint = endpoint
        self.send = send ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, code)
        }
    }

    public func respond(messages: [ChatMessage], tools: [ToolDef]) async throws -> BrainResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encodeBody(messages: messages, tools: tools)

        let (data, status) = try await send(request)
        guard (200..<300).contains(status) else {
            throw NSError(domain: "OpenAIBrainClient", code: status,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "http \(status)"])
        }
        return try decode(data)
    }

    // MARK: - Encoding (Responses API)

    private func encodeBody(messages: [ChatMessage], tools: [ToolDef]) throws -> Data {
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
                // Replay the model's function calls as `function_call` input items (B3).
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

        var body: [String: Any] = [
            "model": model,
            "input": input,
            "tools": toolsJSON,
            "tool_choice": "auto",
            "reasoning": ["effort": reasoningEffort],
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
        let output: [Item]
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
                break
            }
        }
        return BrainResponse(toolCalls: invocations, rawToolCalls: raws)
    }
}
