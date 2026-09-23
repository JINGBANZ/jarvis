import Foundation
import JarvisCore

/// Anthropic's own request shape, sent through the helper's Messages route so tool definitions
/// reach Anthropic untouched. See wiki/architecture.md#subscription-targets-through-the-bundled-proxy.
struct MessagesWireFormat: BrainWireFormat {
    static let apiVersion = "2023-06-01"
    /// A conversation opens with a user turn, and a fresh session's press opens with the runner's
    /// own skill preload.
    static let sessionStart = "Session start."
    static let finishedStopReasons: Set<String> = ["end_turn", "tool_use", "stop_sequence"]

    let model: String
    let reasoningEffort: String
    let maxOutputTokens: Int

    var requestHeaders: [String: String] { ["anthropic-version": Self.apiVersion] }

    func encode(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) throws -> Data {
        var system: [String] = []
        var turns: [[String: Any]] = []

        // Consecutive blocks of one role share a turn, which puts a round's tool results in one
        // user message.
        func append(_ role: String, _ blocks: [[String: Any]]) {
            if var last = turns.last, last["role"] as? String == role {
                last["content"] = (last["content"] as? [[String: Any]] ?? []) + blocks
                turns[turns.count - 1] = last
                return
            }
            if turns.isEmpty, role == "assistant" {
                turns.append(["role": "user", "content": [Self.text(Self.sessionStart)]])
            }
            turns.append(["role": role, "content": blocks])
        }

        for message in messages {
            switch message.role {
            case .system:
                if let text = message.text { system.append(text) }
            case .user:
                if let image = message.imageBase64JPEG {
                    append("user", [["type": "image", "source": [
                        "type": "base64", "media_type": "image/jpeg", "data": image]]])
                } else {
                    append("user", [Self.text(message.text ?? "")])
                }
            case .assistant:
                if let raw = message.rawItemsJSON {
                    // A reply goes back unchanged, so each thinking block precedes its tool_use.
                    append("assistant", raw.compactMap {
                        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
                    })
                } else if let calls = message.toolCalls {
                    append("assistant", calls.map { call in
                        ["type": "tool_use", "id": call.id, "name": call.name,
                         "input": (try? JSONSerialization.jsonObject(
                            with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]]
                    })
                } else if let text = message.text {
                    append("assistant", [Self.text(text)])
                }
            case .tool:
                append("user", [["type": "tool_result", "tool_use_id": message.toolCallId ?? "",
                                 "content": message.text ?? ""]])
            }
        }

        var body: [String: Any] = ["model": model, "max_tokens": maxOutputTokens, "messages": turns]
        if !system.isEmpty {
            body["system"] = system.joined(separator: "\n\n")
        }
        var verbatim = VerbatimJSON()
        if !tools.isEmpty {
            // No `strict`: Anthropic compiles each new strict tool set for seconds, and the catalog
            // enum differs per session, so the first request of every session would pay it. The
            // runner re-asks on a malformed reply instead.
            body["tools"] = try tools.map { tool -> [String: Any] in
                ["name": tool.name, "description": tool.description,
                 "input_schema": try verbatim.placeholder(for: tool.parametersJSON)]
            }
            // Anthropic has no subset choice and Claude Fable 5.1 rejects `any` and `tool`, so the
            // runner's own check enforces a narrowed choice; see wiki/architecture.md#capabilities.
            body["tool_choice"] = [
                "type": "auto",
                "disable_parallel_tool_use": true,   // the coach loop consumes one tool call per turn
            ]
            // Haiku 4.5, the tool-less summarizer's model, rejects both fields.
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": reasoningEffort]
        }
        return try verbatim.data(withJSONObject: body)
    }

    func decode(_ data: Data) throws -> BrainResponse {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "a message is a JSON object"))
        }
        let stopReason = message["stop_reason"] as? String ?? ""
        let finished = Self.finishedStopReasons.contains(stopReason)
        if let usage = message["usage"] as? [String: Any] {
            func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            jlog("Jarvis coach: tokens: input \(count("input_tokens")) "
                 + "(\(count("cache_read_input_tokens")) cached), output \(count("output_tokens")), "
                 + "cap \(maxOutputTokens)" + (finished ? "" : " [\(stopReason)]"))
        }
        if stopReason == "refusal" {
            let details = message["stop_details"] as? [String: Any]
            throw RefusedReply(category: details?["category"] as? String,
                               explanation: details?["explanation"] as? String ?? "")
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        var raws: [RawToolCall] = []
        var invocations: [ToolInvocation] = []
        var text = ""
        for block in blocks {
            switch block["type"] as? String {
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let arguments = String(decoding: try JSONSerialization.data(
                    withJSONObject: block["input"] as? [String: Any] ?? [:],
                    options: [.sortedKeys]), as: UTF8.self)
                raws.append(RawToolCall(id: id, name: name, argumentsJSON: arguments))
                if let invocation = ToolInvocation.parse(callId: id, name: name, argumentsJSON: arguments) {
                    invocations.append(invocation)
                } else {
                    jlog("Jarvis coach: ignoring unknown tool '\(name)'")
                }
            case "text":
                text += block["text"] as? String ?? ""
            default:
                break
            }
        }
        return BrainResponse(
            toolCalls: invocations, rawToolCalls: raws,
            incompleteReason: finished ? nil : (stopReason.isEmpty ? "unknown stop reason" : stopReason),
            outputText: text.isEmpty ? nil : text,
            outputItemsJSON: try blocks.map {
                String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
            })
    }

    private static func text(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }
}
