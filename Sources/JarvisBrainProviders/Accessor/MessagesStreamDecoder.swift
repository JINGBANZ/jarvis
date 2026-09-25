import Foundation
import JarvisCore

/// Assembles the message the unstreamed route would have returned: the `message_start` object,
/// each content block with its deltas applied, and the `message_delta` fields on top. A thinking
/// block keeps its streamed text and signature, so the replayed block is the one Anthropic signed.
struct MessagesStreamDecoder: BrainStreamDecoder {
    private var message: [String: Any]?
    private var blocks: [Int: [String: Any]] = [:]
    /// Partial JSON per `tool_use` block; the final block carries it parsed as `input`.
    private var inputs: [Int: String] = [:]
    private var callOrdinals: [Int: Int] = [:]
    private var stopped = false

    var isComplete: Bool { stopped }

    mutating func receive(_ event: ServerSentEvent) throws -> ToolCallDelta? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(event.data.utf8))) as? [String: Any]
        else { return nil }
        switch object["type"] as? String ?? event.event ?? "" {
        case "message_start":
            message = object["message"] as? [String: Any]
        case "content_block_start":
            guard let index = object["index"] as? Int,
                  let block = object["content_block"] as? [String: Any] else { break }
            blocks[index] = block
            if block["type"] as? String == "tool_use" {
                callOrdinals[index] = callOrdinals.count
                inputs[index] = ""
            }
        case "content_block_delta":
            guard let index = object["index"] as? Int, var block = blocks[index],
                  let delta = object["delta"] as? [String: Any] else { break }
            switch delta["type"] as? String {
            case "input_json_delta":
                let arguments = (inputs[index] ?? "") + (delta["partial_json"] as? String ?? "")
                inputs[index] = arguments
                if let ordinal = callOrdinals[index] {
                    return ToolCallDelta(index: ordinal, name: block["name"] as? String ?? "",
                                         arguments: arguments)
                }
            case "text_delta":
                block["text"] = (block["text"] as? String ?? "") + (delta["text"] as? String ?? "")
            case "thinking_delta":
                block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
            case "signature_delta":
                block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
            default:
                break
            }
            blocks[index] = block
        case "content_block_stop":
            guard let index = object["index"] as? Int, var block = blocks[index],
                  let text = inputs[index] else { break }
            // Text that is not one JSON object reads as an empty input, which the runner answers
            // with the tool's schema like any malformed call.
            block["input"] = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            blocks[index] = block
        case "message_delta":
            var message = self.message ?? [:]
            for (key, value) in object["delta"] as? [String: Any] ?? [:] { message[key] = value }
            if let usage = object["usage"] as? [String: Any] {
                // Cumulative counts, so each replaces the one `message_start` carried.
                var merged = message["usage"] as? [String: Any] ?? [:]
                for (key, value) in usage { merged[key] = value }
                message["usage"] = merged
            }
            self.message = message
        case "message_stop":
            stopped = true
        case "error":
            throw StreamFailure(errorBody: Data(event.data.utf8))
        default:
            break   // `ping`, and event types added later
        }
        return nil
    }

    mutating func finish() throws -> Data {
        guard stopped, var message else { throw StreamFailure(errorBody: nil) }
        message["content"] = blocks.keys.sorted().compactMap { blocks[$0] }
        return try JSONSerialization.data(withJSONObject: message)
    }
}
