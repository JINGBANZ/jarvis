import Foundation
import JarvisCore

extension InteractionsWireFormat {
    static func readRecorded(request: [String: Any]?, response: [String: Any]?) -> RecordedExchange {
        var exchange = RecordedExchange()
        if let request {
            exchange.model = request["model"] as? String
            let config = request["generation_config"] as? [String: Any] ?? [:]
            if let level = config["thinking_level"] {
                exchange.parameters.append(.init(name: "thinking_level", value: RecordedExchange.canonical(level)))
            }
            if let cap = config["max_output_tokens"] {
                exchange.parameters.append(.init(name: "max_output_tokens", value: "\(cap)"))
            }
            let choice = config["tool_choice"]
            if let choice {
                exchange.parameters.append(.init(name: "tool_choice", value: RecordedExchange.canonical(choice)))
            }
            exchange.toolChoiceType = choice as? String ?? (choice as? [String: Any])?.keys.sorted().first
            exchange.instructions = request["system_instruction"] as? String
            exchange.readDeclaredTools(request["tools"])
            let steps = request["input"] as? [Any] ?? []
            exchange.inputFingerprints = steps.map(RecordedExchange.canonical)
            exchange.input = steps.map(inputItem)
        }
        if let response {
            exchange.status = response["status"] as? String
            exchange.outputs = (response["steps"] as? [[String: Any]] ?? [])
                .filter { !inputStepTypes.contains($0["type"] as? String ?? "") }
                .map(output)
            if let usage = response["usage"] {
                let fields = usage as? [String: Any]
                let visible = RecordedExchange.int(fields?["total_output_tokens"])
                let thought = RecordedExchange.int(fields?["total_thought_tokens"])
                exchange.usage = .init(
                    input: RecordedExchange.int(fields?["total_input_tokens"]),
                    cacheRead: RecordedExchange.int(fields?["total_cached_tokens"]),
                    cacheWrite: nil,
                    // Interactions counts thought tokens apart from output.
                    output: visible.map { $0 + (thought ?? 0) },
                    rendered: RecordedExchange.canonical(usage))
            }
        }
        return exchange
    }

    private static func inputItem(_ value: Any) -> RecordedExchange.InputItem {
        guard let step = value as? [String: Any] else { return .other(RecordedExchange.canonical(value)) }
        let content = step["content"] as? [[String: Any]] ?? []
        switch step["type"] as? String {
        case "user_input":
            // An image's `data` holds the recorder's redaction marker.
            return .message(role: "user", parts: content.compactMap { ($0["text"] ?? $0["data"]) as? String })
        case "model_output":
            return .message(role: "assistant", parts: content.compactMap { $0["text"] as? String })
        case "thought":
            return .reasoning(characters: RecordedExchange.canonical(step).count)
        case "function_call":
            return .call(call(step))
        case "function_result":
            return .result(callID: step["call_id"] as? String,
                           output: step["result"].map { $0 as? String ?? RecordedExchange.canonical($0) })
        default:
            return .other(RecordedExchange.canonical(step))
        }
    }

    private static func output(_ step: [String: Any]) -> RecordedExchange.Output {
        switch step["type"] as? String {
        case "function_call":
            return .call(call(step))
        case "model_output":
            return .text((step["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined())
        case "thought":
            return .reasoning
        default:
            return .other(RecordedExchange.canonical(step))
        }
    }

    private static func call(_ step: [String: Any]) -> RecordedExchange.Call {
        .init(id: step["id"] as? String, name: step["name"] as? String,
              arguments: step["arguments"].map(RecordedExchange.canonical))
    }
}
