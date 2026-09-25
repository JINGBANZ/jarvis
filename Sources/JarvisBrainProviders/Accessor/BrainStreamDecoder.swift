import Foundation
import JarvisCore

/// Consumes one reply's events as the reader frames them and ends with the body the unstreamed
/// path would have received, so the accessor records and decodes both the same way.
protocol BrainStreamDecoder {
    /// The terminal event arrived: nothing after it belongs to the reply, so the accessor stops
    /// reading instead of waiting for a close that a stalled connection may never send.
    var isComplete: Bool { get }
    /// The tool call this event extended, if any.
    mutating func receive(_ event: ServerSentEvent) throws -> ToolCallDelta?
    mutating func finish() throws -> Data
}
