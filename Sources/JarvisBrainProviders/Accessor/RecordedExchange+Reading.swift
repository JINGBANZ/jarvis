import Foundation
import JarvisCore

public extension RecordedExchange {
    /// A record's body names its API family, so a session recorded before its provider changed
    /// wire format still reads. Bodies naming none are Responses-shaped or a local CLI's.
    static func read(request: Any?, response: Any?) -> RecordedExchange {
        let request = request as? [String: Any]
        let response = response as? [String: Any]
        if request?["messages"] != nil || response?["type"] as? String == "message" {
            return MessagesWireFormat.readRecorded(request: request, response: response)
        }
        if request?["generation_config"] != nil || request?["system_instruction"] != nil
            || response?["steps"] != nil {
            return InteractionsWireFormat.readRecorded(request: request, response: response)
        }
        return ResponsesWireFormat.readRecorded(request: request, response: response)
    }
}
