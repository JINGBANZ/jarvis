import Foundation
import JarvisCore

/// Forwards function-call argument deltas and keeps the terminal event's `response` object, which
/// is the unstreamed body: usage, `incomplete_details`, and the output items replay byte for byte.
struct ResponsesStreamDecoder: BrainStreamDecoder {
    private struct Call {
        let ordinal: Int
        let name: String
        var arguments: String
    }

    /// Function calls by `output_index`; reasoning and message items take indices of their own.
    private var calls: [Int: Call] = [:]
    private var terminal: [String: Any]?

    mutating func receive(_ event: ServerSentEvent) throws -> ToolCallDelta? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(event.data.utf8))) as? [String: Any]
        else { return nil }
        switch object["type"] as? String ?? event.event ?? "" {
        case "response.output_item.added":
            guard let item = object["item"] as? [String: Any], item["type"] as? String == "function_call",
                  let index = object["output_index"] as? Int else { return nil }
            calls[index] = Call(ordinal: calls.count, name: item["name"] as? String ?? "",
                                arguments: item["arguments"] as? String ?? "")
            return nil
        case "response.function_call_arguments.delta":
            guard let index = object["output_index"] as? Int, var call = calls[index],
                  let delta = object["delta"] as? String else { return nil }
            call.arguments += delta
            calls[index] = call
            return ToolCallDelta(index: call.ordinal, name: call.name, arguments: call.arguments)
        case "response.completed", "response.incomplete":
            terminal = object["response"] as? [String: Any]
            return nil
        case "response.failed":
            let response = object["response"] as? [String: Any]
            throw StreamFailure(errorBody: try JSONSerialization.data(
                withJSONObject: ["error": response?["error"] ?? [:]]))
        case "error":
            // OpenAI sends the fields flat; the bundled helper nests them under `error`.
            let detail = object["error"] as? [String: Any]
                ?? object.filter { $0.key != "type" && $0.key != "sequence_number" }
            throw StreamFailure(errorBody: try JSONSerialization.data(withJSONObject: ["error": detail]))
        default:
            return nil
        }
    }

    mutating func finish() throws -> Data {
        guard let terminal else { throw StreamFailure(errorBody: nil) }
        return try JSONSerialization.data(withJSONObject: terminal)
    }
}
