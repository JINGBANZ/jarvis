import Foundation
import JarvisCore

extension ResponsesWireFormat {
    static func readRecorded(request: [String: Any]?, response: [String: Any]?) -> RecordedExchange {
        var exchange = RecordedExchange()
        if let request {
            exchange.model = request["model"] as? String
            if let reasoning = request["reasoning"] {
                exchange.parameters.append(.init(name: "reasoning", value: RecordedExchange.canonical(reasoning)))
            }
            if let cap = request["max_output_tokens"] {
                exchange.parameters.append(.init(name: "max_output_tokens", value: "\(cap)"))
            }
            let choice = request["tool_choice"]
            if let choice {
                exchange.parameters.append(.init(name: "tool_choice", value: RecordedExchange.canonical(choice)))
            }
            exchange.toolChoiceType = choice as? String ?? (choice as? [String: Any])?["type"] as? String
            exchange.instructions = request["instructions"] as? String
            exchange.readDeclaredTools(request["tools"])
            let items = request["input"] as? [Any] ?? []
            exchange.inputFingerprints = items.map(RecordedExchange.canonical)
            exchange.input = items.map(inputItem)
        }
        if let response {
            exchange.status = response["status"] as? String
            exchange.incompleteDetail = response["incomplete_details"].map(RecordedExchange.canonical)
            exchange.outputs = (response["output"] as? [[String: Any]] ?? []).map(output)
            if let usage = response["usage"] {
                let fields = usage as? [String: Any]
                let details = fields?["input_tokens_details"] as? [String: Any]
                exchange.usage = .init(
                    input: RecordedExchange.int(fields?["input_tokens"]),
                    cacheRead: RecordedExchange.int(details?["cached_tokens"]),
                    cacheWrite: RecordedExchange.int(details?["cache_write_tokens"]),
                    output: RecordedExchange.int(fields?["output_tokens"]),
                    rendered: RecordedExchange.canonical(usage))
            }
        }
        return exchange
    }

    private static func inputItem(_ value: Any) -> RecordedExchange.InputItem {
        guard let item = value as? [String: Any] else { return .other(RecordedExchange.canonical(value)) }
        if let role = item["role"] as? String {
            let parts = (item["content"] as? [[String: Any]] ?? [])
                .compactMap { ($0["text"] ?? $0["image_url"]) as? String }
            return .message(role: role, parts: parts)
        }
        switch item["type"] as? String {
        case "function_call":
            return .call(.init(id: item["call_id"] as? String, name: item["name"] as? String,
                               arguments: item["arguments"] as? String))
        case "function_call_output":
            return .result(callID: item["call_id"] as? String, output: item["output"] as? String)
        case "reasoning":
            return .reasoning(characters: RecordedExchange.canonical(item).count)
        case "text":
            return .text(item["text"] as? String)
        case "image":
            return .image(item["image"] as? String)
        default:
            return .other(RecordedExchange.canonical(item))
        }
    }

    private static func output(_ item: [String: Any]) -> RecordedExchange.Output {
        switch item["type"] as? String {
        case "function_call":
            return .call(.init(id: item["call_id"] as? String, name: item["name"] as? String,
                               arguments: item["arguments"] as? String))
        case "message":
            return .text((item["content"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }.joined())
        case "reasoning":
            return .reasoning
        default:
            return .other(RecordedExchange.canonical(item))
        }
    }
}
