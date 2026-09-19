import Foundation
import JarvisCore

extension MessagesWireFormat {
    static func readRecorded(request: [String: Any]?, response: [String: Any]?) -> RecordedExchange {
        var exchange = RecordedExchange()
        if let request {
            exchange.model = request["model"] as? String
            if let config = request["output_config"] {
                exchange.parameters.append(.init(name: "output_config", value: RecordedExchange.canonical(config)))
            }
            if let cap = request["max_tokens"] {
                exchange.parameters.append(.init(name: "max_tokens", value: "\(cap)"))
            }
            let choice = request["tool_choice"]
            if let choice {
                exchange.parameters.append(.init(name: "tool_choice", value: RecordedExchange.canonical(choice)))
            }
            exchange.toolChoiceType = (choice as? [String: Any])?["type"] as? String
            exchange.instructions = request["system"] as? String
            exchange.readDeclaredTools(request["tools"])
            // One item per content block, so a turn that grows by a block keeps its earlier
            // fingerprints; the transcript pairs each fingerprint with its item.
            for turn in request["messages"] as? [[String: Any]] ?? [] {
                let role = turn["role"] as? String ?? "?"
                for block in turn["content"] as? [[String: Any]] ?? [] {
                    exchange.inputFingerprints.append(RecordedExchange.canonical(["role": role, "block": block]))
                    exchange.input.append(inputItem(role: role, block: block))
                }
            }
        }
        if let response {
            exchange.status = response["stop_reason"] as? String
            // Set only on a refusal; every other reply carries `stop_details: null`.
            exchange.incompleteDetail = (response["stop_details"] as? [String: Any]).map(RecordedExchange.canonical)
            exchange.outputs = (response["content"] as? [[String: Any]] ?? []).map(output)
            if let usage = response["usage"] {
                let fields = usage as? [String: Any]
                exchange.usage = .init(
                    input: RecordedExchange.int(fields?["input_tokens"]),
                    cacheRead: RecordedExchange.int(fields?["cache_read_input_tokens"]),
                    cacheWrite: RecordedExchange.int(fields?["cache_creation_input_tokens"]),
                    output: RecordedExchange.int(fields?["output_tokens"]),
                    rendered: RecordedExchange.canonical(usage))
            }
        }
        return exchange
    }

    private static func inputItem(role: String, block: [String: Any]) -> RecordedExchange.InputItem {
        switch block["type"] as? String {
        case "text":
            return .message(role: role, parts: [block["text"] as? String ?? ""])
        case "image":
            // The image's `data` holds the recorder's redaction marker.
            return .message(role: role, parts: [(block["source"] as? [String: Any])?["data"] as? String ?? ""])
        case "tool_use":
            return .call(call(block))
        case "tool_result":
            return .result(callID: block["tool_use_id"] as? String,
                           output: block["content"].map { $0 as? String ?? RecordedExchange.canonical($0) })
        case "thinking", "redacted_thinking":
            return .reasoning(characters: RecordedExchange.canonical(block).count)
        default:
            return .other(RecordedExchange.canonical(block))
        }
    }

    private static func output(_ block: [String: Any]) -> RecordedExchange.Output {
        switch block["type"] as? String {
        case "tool_use":
            return .call(call(block))
        case "text":
            return .text(block["text"] as? String ?? "")
        case "thinking", "redacted_thinking":
            return .reasoning
        default:
            return .other(RecordedExchange.canonical(block))
        }
    }

    private static func call(_ block: [String: Any]) -> RecordedExchange.Call {
        .init(id: block["id"] as? String, name: block["name"] as? String,
              arguments: block["input"].map(RecordedExchange.canonical))
    }
}
