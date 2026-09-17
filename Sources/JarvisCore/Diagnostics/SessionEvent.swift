import Foundation

// Design: wiki/session-audit.md#one-event-two-projections
public struct SessionEvent: Sendable {
    public static let currentVersion = 1

    /// Persisted identifiers: a shipped raw value never changes.
    public enum Kind: String, Sendable {
        case brainTraffic = "brain_traffic"
        case coachingAttempt = "coaching_attempt"
        case diagnostic = "diagnostic"
        case activity = "activity"
    }

    public enum Detail: Sendable {
        case brainTraffic(BrainTrafficAuditEvent)
        case coachingAttempt(CoachingAttemptAuditEvent)
        case diagnostic(DiagnosticAuditEvent)
        case activity(ActivityAuditEvent)
    }

    public let version: Int
    /// Stamped at admission, so a closing session's late work never lands on its replacement.
    public let sessionID: UUID
    /// When the producer handed it over; `occurredAt` is when it happened.
    public let recordedAt: Date
    public let detail: Detail

    public init(
        sessionID: UUID,
        detail: Detail,
        recordedAt: Date = Date()
    ) {
        self.version = Self.currentVersion
        self.sessionID = sessionID
        self.detail = detail
        self.recordedAt = recordedAt
    }

    public var activityPresentation: ActivityEvent? {
        switch detail {
        case .activity(let event): event.presentation
        case .brainTraffic, .coachingAttempt, .diagnostic: nil
        }
    }

    public var kind: Kind {
        switch detail {
        case .brainTraffic: .brainTraffic
        case .coachingAttempt: .coachingAttempt
        case .diagnostic: .diagnostic
        case .activity: .activity
        }
    }

    public var occurredAt: Date {
        switch detail {
        case .brainTraffic(let event): event.date
        case .coachingAttempt(.started(let event)): event.date
        case .coachingAttempt(.finished(let event)): event.date
        case .diagnostic(let event): event.date
        case .activity(let event): event.date
        }
    }

    /// Nil for traffic outside a coaching attempt, such as the summarizer.
    public var attemptID: Int? {
        switch detail {
        case .brainTraffic(let event): event.requestContext?.attemptID
        case .coachingAttempt(.started(let event)): event.attemptID
        case .coachingAttempt(.finished(let event)): event.attemptID
        // `jlog` takes no attempt, and inferring one would invent attribution.
        case .diagnostic: nil
        case .activity: nil
        }
    }

    /// Includes a screen view's retained JPEG, the largest thing an envelope keeps in memory.
    var approximateRetainedBytes: Int {
        var bytes = 64
        switch detail {
        case .brainTraffic(let event):
            bytes = Self.adding(bytes, event.approximateRetainedBytes)
        case .coachingAttempt(let event):
            bytes = Self.adding(bytes, event.approximateRetainedBytes)
        case .diagnostic(let event):
            bytes = Self.adding(bytes, event.approximateRetainedBytes)
        case .activity(let event):
            bytes = Self.adding(bytes, event.approximateRetainedBytes)
        }
        return bytes
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
