import Foundation

public struct ReferenceAccessFailure: Error, Equatable, Sendable {
    public enum Reason: String, Sendable {
        case preparing, unavailable, failed, superseded, released
        case unknownDocument = "unknown_document", unknownSession = "unknown_session"
        case invalidOffset = "invalid_offset", invalidCursor = "invalid_cursor"
        case revisionMismatch = "revision_mismatch", sourceChanged = "source_changed"
        case unsupportedFormat = "unsupported_format", limitExceeded = "limit_exceeded"
        case resourceLimit = "resource_limit", cacheFull = "cache_full", diskFull = "disk_full"
        case conversionTimeout = "conversion_timeout", invalidDocument = "invalid_document"
        case duplicateStart = "duplicate_start", abandonedStart = "abandoned_start"
    }
    public let reason: Reason

    public init(reason: Reason) { self.reason = reason }
}
