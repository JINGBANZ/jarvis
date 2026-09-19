import Foundation

/// A `speak` reply as far as it has streamed. Each snapshot is the whole state, so a panel that
/// shows it remembers nothing between updates.
public struct BrainReplyProgress: Sendable, Equatable {
    /// Lines whose closing quote arrived, blank ones dropped as `ToolInvocation.parse` drops them.
    public let closedLines: [String]
    /// The line still being written.
    public let openLine: String?
    /// The closing bracket of `lines` arrived.
    public let linesComplete: Bool
    /// The detail text so far; nil until its opening quote.
    public let detailMarkdown: String?

    public init(closedLines: [String], openLine: String?, linesComplete: Bool, detailMarkdown: String?) {
        self.closedLines = closedLines
        self.openLine = openLine
        self.linesComplete = linesComplete
        self.detailMarkdown = detailMarkdown
    }

    /// Anything a panel could show.
    public var hasText: Bool {
        !closedLines.isEmpty || openLine?.isEmpty == false || detailMarkdown?.isEmpty == false
    }
}
