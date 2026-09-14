import Foundation

/// Semantic or recognized text accompanying one screenshot. Source and coverage travel with the
/// text so callers cannot accidentally treat a viewport OCR result as a complete document.
public struct ScreenTextEvidence: Sendable, Equatable {
    public enum Source: String, Sendable, Codable {
        case browserAccessibility
        case onDeviceOCR
    }

    public enum Coverage: String, Sendable, Codable {
        /// Text exposed by the foreground browser tab's accessibility tree. The tree may include
        /// off-screen content, but it is not a completeness claim about the DOM or editor buffer.
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

    /// OCR cannot support exact historical claims after its source image leaves the request.
    public var isRetainable: Bool {
        source == .browserAccessibility && coverage == .activeTabAccessibilityTree
    }
}
