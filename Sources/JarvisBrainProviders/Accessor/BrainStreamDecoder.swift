import Foundation
import JarvisCore

/// Consumes one reply's events as the reader frames them and ends with the body the unstreamed
/// path would have received, so the accessor records and decodes both the same way.
protocol BrainStreamDecoder {
    /// The tool call this event extended, if any.
    mutating func receive(_ event: ServerSentEvent) throws -> ToolCallDelta?
    mutating func finish() throws -> Data
}

/// The reply did not reach its terminal event. `errorBody` is the provider's error event in the
/// shape its failure table reads; nil when the stream simply closed.
struct StreamFailure: Error {
    let errorBody: Data?
}
