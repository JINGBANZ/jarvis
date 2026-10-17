import Foundation

enum ReferenceStoreError: String, Error, Sendable {
    case unavailable, unknown_document, unknown_session, invalid_offset, invalid_cursor
    case revision_mismatch, source_changed, unsupported_format, limit_exceeded, resource_limit
    case cache_full, disk_full, preparing, superseded, released, failed, invalid_source
}
