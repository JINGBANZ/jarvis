import Foundation
import JarvisCore

public extension RecordedExchange {
    /// Records naming no current provider predate provider descriptors; their bodies were
    /// Responses-shaped or a local CLI's.
    static func read(provider: String?, request: Any?, response: Any?) -> RecordedExchange {
        let request = request as? [String: Any]
        let response = response as? [String: Any]
        switch provider.flatMap(BrainProvider.init(rawValue:))?.descriptor.wire {
        case .responses, nil:
            return ResponsesWireFormat.readRecorded(request: request, response: response)
        case .interactions:
            return InteractionsWireFormat.readRecorded(request: request, response: response)
        }
    }
}
