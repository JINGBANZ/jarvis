import Foundation
import JarvisCore

struct ResponsesWireFormat: BrainWireFormat {
    // The helper reuses this as the upstream session id on the Codex path, so it must stay stable.
    static let promptCacheKey = "jarvis-coach-v1"

    let model: String
    let reasoningEffort: String
    let maxOutputTokens: Int
    /// True deliberately retains transcripts and screenshots at OpenAI for dashboard debugging
    /// (wiki/sandbox.md); subscription targets pass false so a helper bump can't turn it back on.
    let store: Bool

    func encode(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) throws -> Data {
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
                // OpenAI requires a function call's output items, reasoning included, to be replayed
                // unmodified and in order. Raw items already contain the calls, so they are sent alone.
                if let raw = m.rawItemsJSON {
                    for itemJSON in raw {
                        if let item = (try? JSONSerialization.jsonObject(with: Data(itemJSON.utf8))) as? [String: Any] {
                            input.append(item)
                        }
                    }
                } else if let calls = m.toolCalls {
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
            // Responses uses a flat function tool shape. `strict` requires every object in the
            // schema to set additionalProperties:false and list all keys as required.
            return ["type": "function", "name": t.name, "description": t.description,
                    "parameters": params, "strict": true]
        }

        // A subset narrows tool_choice, not the declared tools, so the cached prefix holds.
        let toolChoiceJSON: Any
        switch toolChoice {
        case .auto: toolChoiceJSON = "auto"
        case .required: toolChoiceJSON = "required"
        case .allowed(let names):
            toolChoiceJSON = [
                "type": "allowed_tools",
                "mode": "required",
                "tools": names.map { ["type": "function", "name": $0] },
            ] as [String: Any]
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
            "store": store,
            "prompt_cache_key": Self.promptCacheKey,
        ]
        if !instructions.isEmpty {
            body["instructions"] = instructions.joined(separator: "\n\n")
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            struct ContentPart: Decodable {
                let type: String
                let text: String?
            }
            let type: String
            let call_id: String?
            let name: String?
            let arguments: String?
            let content: [ContentPart]?
        }
        struct IncompleteDetails: Decodable { let reason: String? }
        struct Usage: Decodable {
            struct InputDetails: Decodable { let cached_tokens: Int? }
            struct OutputDetails: Decodable { let reasoning_tokens: Int? }
            let input_tokens: Int?
            let input_tokens_details: InputDetails?
            let output_tokens: Int?
            let output_tokens_details: OutputDetails?
        }
        let output: [Item]
        let status: String?
        let incomplete_details: IncompleteDetails?
        let usage: Usage?
    }

    func decode(_ data: Data) throws -> BrainResponse {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        // Logged to tune the per-effort budgets from real use. History is append-only to keep
        // `cached` high, so a run of zeros needs investigating.
        if let usage = decoded.usage {
            let input = usage.input_tokens ?? 0
            let cached = usage.input_tokens_details?.cached_tokens ?? 0
            let reasoning = usage.output_tokens_details?.reasoning_tokens ?? 0
            let truncated = decoded.status == "incomplete" ? " [incomplete]" : ""
            jlog("Jarvis coach: tokens — input \(input) (\(cached) cached), reasoning \(reasoning), output \(usage.output_tokens ?? 0), cap \(maxOutputTokens)\(truncated)")
        }
        var invocations: [ToolInvocation] = []
        var raws: [RawToolCall] = []
        // Unused by coaching turns, but the whole payload of a tool-less summarizer call.
        let outputText = decoded.output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined()
        for item in decoded.output where item.type == "function_call" {
            guard let callId = item.call_id, let name = item.name else { continue }
            let args = item.arguments ?? "{}"
            raws.append(RawToolCall(id: callId, name: name, argumentsJSON: args))
            if let invocation = ToolInvocation.parse(callId: callId, name: name, argumentsJSON: args) {
                invocations.append(invocation)
            } else {
                jlog("Jarvis coach: ignoring unknown tool '\(name)'")
            }
        }
        // A truncated run can carry zero tool calls; the reason keeps it from reading as a silence.
        let incompleteReason = decoded.status == "incomplete"
            ? (decoded.incomplete_details?.reason ?? "incomplete")
            : nil
        return BrainResponse(toolCalls: invocations, rawToolCalls: raws,
                             incompleteReason: incompleteReason,
                             outputText: outputText.isEmpty ? nil : outputText,
                             outputItemsJSON: Self.outputItemsJSON(in: data))
    }

    /// Read from the raw bytes because replay must keep fields `Response` doesn't model, such as
    /// reasoning ids and encrypted payloads.
    private static func outputItemsJSON(in data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else { return [] }
        return output.compactMap { item in
            guard let bytes = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
    }
}
