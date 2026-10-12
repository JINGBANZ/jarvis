import Foundation

/// A `speak` reply as far as it has streamed. Each snapshot is the whole state, so a panel that
/// shows it remembers nothing between updates.
public struct BrainReplyProgress: Sendable, Equatable {
    public let hint: String
    /// The hint's closing quote arrived.
    public let hintComplete: Bool
    /// The detail text so far; nil until its opening quote.
    public let detailMarkdown: String?

    public init(hint: String, hintComplete: Bool, detailMarkdown: String?) {
        self.hint = hint
        self.hintComplete = hintComplete
        self.detailMarkdown = detailMarkdown
    }

    /// Anything a panel could show.
    public var hasText: Bool {
        !hint.isEmpty || detailMarkdown?.isEmpty == false
    }
}
