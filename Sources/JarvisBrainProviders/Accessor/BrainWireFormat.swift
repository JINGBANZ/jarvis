import Foundation
import JarvisCore

/// Tools arrive already resolved by the target's `ToolChoicePolicy`. See wiki/architecture.md
/// for the replay rule every format follows.
protocol BrainWireFormat: Sendable {
    func encode(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) throws -> Data
    func decode(_ data: Data) throws -> BrainResponse
}
