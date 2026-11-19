import Foundation

public enum TranscriptTimingSource: String, Sendable {
    case providerOffsets
    case localUtterance
    case localActivityEstimate
    case audioWindowEstimate
}
