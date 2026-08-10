import Foundation

/// Provider-facing, best-effort session-audit port.
///
/// Implementations must return immediately, must not throw, and must never invoke coaching callbacks.
public protocol BrainTrafficAuditing: Sendable {
    func record(_ event: BrainTrafficAuditEvent)
}

public extension BrainTrafficAuditing {
    func record(
        tag: String,
        request: Data,
        response: Data?,
        status: Int?,
        latencyMs: Int,
        error: String? = nil,
        phases: [String: Int]? = nil,
        kind: BrainTrafficAuditEvent.Kind = .providerCall,
        at date: Date = Date()
    ) {
        record(BrainTrafficAuditEvent(
            tag: tag,
            request: request,
            response: response,
            status: status,
            latencyMs: latencyMs,
            error: error,
            phases: phases,
            kind: kind,
            requestContext: tag == "coach" ? CoachingRequestAttribution.current : nil,
            date: date))
    }
}
