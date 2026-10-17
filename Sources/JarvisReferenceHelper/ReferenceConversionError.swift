import Foundation

enum ReferenceConversionError: String, Error, Sendable, CaseIterable {
    case unavailable
    case sourceChanged = "source_changed"
    case unsupportedFormat = "unsupported_format"
    case limitExceeded = "limit_exceeded"
    case resourceLimit = "resource_limit"
    case conversionTimeout = "conversion_timeout"
    case invalidDocument = "invalid_document"
    case diskFull = "disk_full"

    static func classify(_ error: Error, fallback: Self = .unavailable) -> Self {
        if let known = error as? Self { return known }
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain && failure.code == ENOSPC
            || failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return .diskFull
        }
        if let cause = failure.userInfo[NSUnderlyingErrorKey] as? NSError,
           cause.domain == NSPOSIXErrorDomain && cause.code == ENOSPC { return .diskFull }
        return fallback
    }

    var exitStatus: Int32 { Int32(Self.allCases.firstIndex(of: self)! + 20) }

    init(exitStatus: Int32) {
        self = Self.allCases.first { $0.exitStatus == exitStatus } ?? .invalidDocument
    }
}
