import Foundation
import JarvisCore

/// Stateless (`store: false`). The live API enforces rules its reference omits; each is noted
/// where it applies and pinned by a test. See wiki/architecture.md.
struct InteractionsWireFormat: BrainWireFormat {
    /// Google documents this signature for injected calls on generateContent, and Interactions
    /// accepts it: every `function_call` needs a signed thought step before it, or the request is a
    /// 400. Calls Gemini just returned carry their own.
    static let placeholderThought = ["type": "thought", "signature": "skip_thought_signature_validator"]
    /// A call may only follow a user step or a function result, so input can't open with one.
    static let sessionStart = "Session start."
    static let finishedStatuses: Set<String> = ["completed", "requires_action"]
    /// A reply may echo these; they are never the model's output.
    static let inputStepTypes: Set<String> = ["user_input", "function_result"]

    let model: String
    let reasoningEffort: String
    let maxOutputTokens: Int

    func encode(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) throws -> Data {
        var instructions: [String] = []
        var input: [[String: Any]] = []
        // `function_result` needs its call's name in practice, though the reference says optional.
        // Memory keeps every result beside its call, so the name is always found.
        var callNames: [String: String] = [:]

        for message in messages {
            switch message.role {
            case .system:
                if let text = message.text { instructions.append(text) }
            case .user:
                let content: [String: Any] = if let image = message.imageBase64JPEG {
                    ["type": "image", "mime_type": "image/jpeg", "data": image]
                } else {
                    ["type": "text", "text": message.text ?? ""]
                }
                input.append(["type": "user_input", "content": [content]])
            case .assistant:
                if let raw = message.rawItemsJSON {
                    if input.isEmpty { input.append(Self.userText(Self.sessionStart)) }
                    for json in raw {
                        guard let step = (try? JSONSerialization.jsonObject(
                            with: Data(json.utf8))) as? [String: Any] else { continue }
                        if step["type"] as? String == "function_call",
                           let id = step["id"] as? String, let name = step["name"] as? String {
                            callNames[id] = name
                        }
                        input.append(step)
                    }
                } else if let calls = message.toolCalls {
                    if input.isEmpty { input.append(Self.userText(Self.sessionStart)) }
                    input.append(Self.placeholderThought)
                    for call in calls {
                        callNames[call.id] = call.name
                        let arguments = (try? JSONSerialization.jsonObject(
                            with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
                        input.append(["type": "function_call", "id": call.id,
                                      "name": call.name, "arguments": arguments])
                    }
                } else if let text = message.text {
                    input.append(["type": "model_output", "content": [["type": "text", "text": text]]])
                }
            case .tool:
                let id = message.toolCallId ?? ""
                input.append(["type": "function_result", "call_id": id,
                              "name": callNames[id] ?? "", "result": message.text ?? ""])
            }
        }

        var config: [String: Any] = [
            // The models that reject `minimal` floor at low in the catalog.
            "thinking_level": reasoningEffort == ReasoningEffort.none.rawValue ? "minimal" : reasoningEffort,
            "thinking_summaries": "none",
            "max_output_tokens": maxOutputTokens,
        ]
        var body: [String: Any] = ["model": model, "input": input, "store": false]
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool -> [String: Any] in
                ["type": "function", "name": tool.name, "description": tool.description,
                 "parameters": try JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))]
            }
            // Top-level `tool_choice` and any parallel-call field are 400s; the runner answers extra
            // calls itself.
            let choice: Any
            switch toolChoice {
            case .auto: choice = "auto"
            case .required: choice = "any"
            case .allowed(let names):
                choice = ["allowed_tools": ["mode": "any", "tools": names] as [String: Any]]
            case .force(let name):
                choice = ["allowed_tools": ["mode": "any", "tools": [name]] as [String: Any]]
            }
            config["tool_choice"] = choice
        }
        body["generation_config"] = config
        if !instructions.isEmpty {
            body["system_instruction"] = instructions.joined(separator: "\n\n")
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    func decode(_ data: Data) throws -> BrainResponse {
        guard let interaction = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "an interaction is a JSON object"))
        }
        let status = interaction["status"] as? String ?? ""
        let finished = Self.finishedStatuses.contains(status)
        if let usage = interaction["usage"] as? [String: Any] {
            func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            jlog("Jarvis coach: tokens: input \(count("total_input_tokens")) "
                 + "(\(count("total_cached_tokens")) cached), reasoning \(count("total_thought_tokens")), "
                 + "output \(count("total_output_tokens")), cap \(maxOutputTokens)"
                 + (finished ? "" : " [\(status)]"))
        }
        // Returned ids are `call_` plus at most six digits, which a long session can repeat.
        let suffix = "_" + UUID().uuidString.prefix(8).lowercased()
        var steps: [[String: Any]] = []
        var raws: [RawToolCall] = []
        var invocations: [ToolInvocation] = []
        var text = ""
        for var step in interaction["steps"] as? [[String: Any]] ?? [] {
            let type = step["type"] as? String ?? ""
            guard !Self.inputStepTypes.contains(type) else { continue }
            switch type {
            case "function_call":
                guard let id = step["id"] as? String, let name = step["name"] as? String else { continue }
                let unique = id + suffix
                step["id"] = unique
                let arguments = String(decoding: try JSONSerialization.data(
                    withJSONObject: step["arguments"] as? [String: Any] ?? [:],
                    options: [.sortedKeys]), as: UTF8.self)
                raws.append(RawToolCall(id: unique, name: name, argumentsJSON: arguments))
                if let invocation = ToolInvocation.parse(callId: unique, name: name, argumentsJSON: arguments) {
                    invocations.append(invocation)
                } else {
                    jlog("Jarvis coach: ignoring unknown tool '\(name)'")
                }
            case "model_output":
                text += (step["content"] as? [[String: Any]] ?? [])
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined()
            default:
                break
            }
            steps.append(step)
        }
        return BrainResponse(
            toolCalls: invocations, rawToolCalls: raws,
            incompleteReason: finished ? nil : Self.unfinishedReason(status, errors: interaction["errors"]),
            outputText: text.isEmpty ? nil : text,
            outputItemsJSON: try steps.map {
                String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
            })
    }

    /// A `failed` interaction names its cause only in `errors`.
    private static func unfinishedReason(_ status: String, errors: Any?) -> String {
        let name = status.isEmpty ? "unknown status" : status
        let causes = (errors as? [[String: Any]] ?? []).map { error in
            [error["code"] as? String, error["message"] as? String]
                .compactMap { $0 }.joined(separator: ": ")
        }.filter { !$0.isEmpty }
        return causes.isEmpty ? name : "\(name) (\(causes.joined(separator: "; ")))"
    }

    private static func userText(_ text: String) -> [String: Any] {
        ["type": "user_input", "content": [["type": "text", "text": text]]]
    }
}
