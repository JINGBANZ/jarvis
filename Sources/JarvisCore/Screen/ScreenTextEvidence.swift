import Foundation

public struct ScreenTextEvidence: Sendable, Equatable {
    public enum Source: String, Sendable, Codable {
        case browserAccessibility
        case onDeviceOCR
    }

    public enum Coverage: String, Sendable, Codable {
        /// May include off-screen text, but is not the complete DOM or editor buffer.
        case activeTabAccessibilityTree
        case currentViewport
    }

    public let text: String
    public let source: Source
    public let coverage: Coverage
    public let truncated: Bool

    public init(text: String, source: Source, coverage: Coverage, truncated: Bool = false) {
        self.text = text
        self.source = source
        self.coverage = coverage
        self.truncated = truncated
    }
}
