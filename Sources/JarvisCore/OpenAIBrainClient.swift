import Foundation

public struct OpenAIBrainClient: BrainClient, @unchecked Sendable {
    public typealias Sender = @Sendable (URLRequest) async throws -> (Data, Int)

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let send: Sender

    /// `send` defaults to URLSession; tests inject a stub returning (body, statusCode).
    public init(apiKey: String,
                model: String,
                endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
                send: Sender? = nil) {
        self.apiKey = apiKey
        self.model = model
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

    // MARK: - Encoding

    private func encodeBody(messages: [ChatMessage], tools: [ToolDef]) throws -> Data {
        var msgs: [[String: Any]] = []
        for m in messages {
            // Assistant message replaying tool calls (B3): must precede any tool result.
            if m.role == .assistant, let calls = m.toolCalls {
                msgs.append([
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": calls.map { [
                        "id": $0.id,
                        "type": "function",
                        "function": ["name": $0.name, "arguments": $0.argumentsJSON],
                    ] },
                ])
                continue
            }
            switch m.role {
            case .system, .assistant:
                msgs.append(["role": m.role.rawValue, "content": m.text ?? ""])
            case .user:
                if let img = m.imageBase64JPEG {
                    msgs.append([
                        "role": "user",
                        "content": [["type": "image_url",
                                     "image_url": ["url": "data:image/jpeg;base64,\(img)"]]],
                    ])
                } else {
                    msgs.append(["role": "user", "content": m.text ?? ""])
                }
            case .tool:
                msgs.append(["role": "tool",
                             "tool_call_id": m.toolCallId ?? "",
                             "content": m.text ?? ""])
            }
        }
        let toolsJSON: [[String: Any]] = try tools.map { t in
            let params = try JSONSerialization.jsonObject(with: Data(t.parametersJSON.utf8))
            return ["type": "function",
                    "function": ["name": t.name, "description": t.description, "parameters": params]]
        }
        let body: [String: Any] = [
            "model": model,
            "messages": msgs,
            "tools": toolsJSON,
            "tool_choice": "auto",
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Decoding

    private struct Response: Decodable {
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let tool_calls: [ToolCall]? }
        struct ToolCall: Decodable {
            let id: String
            let function: Function
        }
        struct Function: Decodable { let name: String; let arguments: String }
        let choices: [Choice]
    }

    private func decode(_ data: Data) throws -> BrainResponse {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let calls = decoded.choices.first?.message.tool_calls else {
            return BrainResponse(toolCalls: [])
        }
        var invocations: [ToolInvocation] = []
        var raws: [RawToolCall] = []
        for c in calls {
            raws.append(RawToolCall(id: c.id, name: c.function.name, argumentsJSON: c.function.arguments))
            switch c.function.name {
            case "capture_screen":
                invocations.append(.captureScreen(callId: c.id))
            case "speak":
                let text = (try? JSONDecoder().decode([String: String].self,
                                                      from: Data(c.function.arguments.utf8)))?["text"] ?? ""
                invocations.append(.speak(callId: c.id, text: text))
            default:
                break
            }
        }
        return BrainResponse(toolCalls: invocations, rawToolCalls: raws)
    }
}
