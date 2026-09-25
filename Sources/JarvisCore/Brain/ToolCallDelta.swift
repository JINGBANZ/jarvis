import Foundation

/// One tool call's arguments as far as the provider has streamed them. `index` counts the reply's
/// calls from zero, whatever the reply carries ahead of them.
public struct ToolCallDelta: Sendable, Equatable {
    public let index: Int
    public let name: String
    /// The argument text received so far, not this event's fragment.
    public let arguments: String

    public init(index: Int, name: String, arguments: String) {
        self.index = index
        self.name = name
        self.arguments = arguments
    }
}

/// Runs on the transport's reading task with each streamed delta. The request phases it returns
/// are stamped into the recorded traffic with the elapsed time, the first time each is reported,
/// so the transport records the moments the caller recognized without knowing any tool.
public typealias ToolCallProgressSink = @Sendable (ToolCallDelta) -> [String]
