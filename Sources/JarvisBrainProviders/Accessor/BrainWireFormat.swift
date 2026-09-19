import Foundation
import JarvisCore

/// Tools arrive already resolved by the target's `ToolChoicePolicy`. See wiki/architecture.md
/// for the replay rule every format follows.
protocol BrainWireFormat: Sendable {
    /// Headers the API family requires beyond the content type and the key.
    var requestHeaders: [String: String] { get }
    func encode(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) throws -> Data
    func decode(_ data: Data) throws -> BrainResponse
}

extension BrainWireFormat {
    var requestHeaders: [String: String] { [:] }
}

/// A 2xx reply the model declined to finish. The accessor names the provider it came from.
struct RefusedReply: Error {
    let category: String?
    let explanation: String
}
