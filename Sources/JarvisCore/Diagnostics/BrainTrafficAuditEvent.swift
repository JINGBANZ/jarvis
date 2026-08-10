import Foundation

/// One provider-boundary observation retained by the session audit worker.
///
/// The event deliberately keeps request and response bodies as bytes. JSON parsing, image redaction,
/// serialization, and file access all happen after bounded mailbox admission, never on the provider
/// response path.
public struct BrainTrafficAuditEvent: Sendable {
    public enum Kind: String, Sendable {
        case providerCall = "provider_call"
        case preRequestFailure = "pre_request_failure"
    }

    public let tag: String
    public let request: Data
    public let response: Data?
    public let status: Int?
    public let latencyMs: Int
    public let error: String?
    public let phases: [String: Int]?
    public let kind: Kind
    public let requestContext: CoachingRequestContext?
    public let date: Date

    var approximateRetainedBytes: Int {
        var bytes = 256
        bytes = Self.adding(bytes, request.count)
        bytes = Self.adding(bytes, response?.count ?? 0)
        bytes = Self.adding(bytes, tag.utf8.count)
        bytes = Self.adding(bytes, error?.utf8.count ?? 0)
        for (key, _) in phases ?? [:] {
            bytes = Self.adding(bytes, key.utf8.count + MemoryLayout<Int>.size)
        }
        if let requestContext {
            bytes = Self.adding(bytes, requestContext.approximateRetainedBytes)
        }
        return bytes
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
