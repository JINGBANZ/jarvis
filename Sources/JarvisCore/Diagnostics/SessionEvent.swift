import Foundation

/// The one versioned envelope for a session-evidence occurrence.
///
/// Phase 1 expand step of the lean coaching core ("One Event, Two Projections" in
/// wiki/lean-coaching-core.md): every occurrence admitted to the shared bounded session-evidence
/// transport travels as one `SessionEvent`. The narrow producer ports — `BrainTrafficAuditing`,
/// `CoachingAttemptAuditing`, and `ActivityEventRecording` — remain typed views that wrap their
/// detail into this envelope on the one per-session handle; they are not separate queues, workers,
/// health records, or lifecycles.
///
/// Persisted record files keep their own schemas and `audit_version`. This envelope carries its own
/// version so a later persisted projection of the envelope itself can evolve independently of any
/// single record file.
public struct SessionEvent: Sendable {
    /// The envelope-shape version stamped on every event.
    public static let currentVersion = 1

    /// Stable identity of the occurrence category. Raw values are persisted-projection-grade
    /// identifiers: once a kind ships, its raw value never changes.
    public enum Kind: String, Sendable {
        case brainTraffic = "brain_traffic"
        case coachingAttempt = "coaching_attempt"
        case diagnostic = "diagnostic"
        case activity = "activity"
    }

    /// The full typed payload of one occurrence. Later slices add cases here — a new producer
    /// category joins the envelope, never a second admission stack.
    public enum Detail: Sendable {
        case brainTraffic(BrainTrafficAuditEvent)
        case coachingAttempt(CoachingAttemptAuditEvent)
        case diagnostic(DiagnosticAuditEvent)
        case activity(ActivityAuditEvent)
    }

    public let version: Int
    /// Identity of the originating session handle. Every event is stamped at admission so late
    /// work from a closing session can never be attributed to its replacement.
    public let sessionID: UUID
    /// When the producer handed the occurrence to the transport. The occurrence itself is
    /// timestamped by `occurredAt`.
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

    /// Closed human-safe copy for the Activity projection, derived from the typed detail rather
    /// than stored beside it. `ActivityEvent` is the closed presentation set, so the shared stack
    /// never opens a generic path for producers to author human-facing strings; deriving it is what
    /// makes "one occurrence produces one event" structural — an occurrence cannot carry human copy
    /// that disagrees with, or duplicates, what its detail says happened.
    public var activityPresentation: ActivityEvent? {
        switch detail {
        case .activity(let event): event.presentation
        case .brainTraffic, .coachingAttempt, .diagnostic: nil
        }
    }

    /// Derived from `detail` so the stable kind can never disagree with the typed payload.
    public var kind: Kind {
        switch detail {
        case .brainTraffic: .brainTraffic
        case .coachingAttempt: .coachingAttempt
        case .diagnostic: .diagnostic
        case .activity: .activity
        }
    }

    /// When the occurrence happened, as its typed detail recorded it. Derived rather than stored
    /// twice so envelope timing cannot drift from what the persisted record encodes.
    public var occurredAt: Date {
        switch detail {
        case .brainTraffic(let event): event.date
        case .coachingAttempt(.started(let event)): event.date
        case .coachingAttempt(.finished(let event)): event.date
        case .diagnostic(let event): event.date
        case .activity(let event): event.date
        }
    }

    /// Attempt attribution where applicable: nil for traffic outside a coaching attempt, such as
    /// the summarizer. Derived from the detail's own attribution for the same no-drift reason.
    public var attemptID: Int? {
        switch detail {
        case .brainTraffic(let event): event.requestContext?.attemptID
        case .coachingAttempt(.started(let event)): event.attemptID
        case .coachingAttempt(.finished(let event)): event.attemptID
        // Diagnostics are session-attributed, never attempt-attributed: `jlog` has no attempt
        // parameter, and inferring one from ambient state would invent attribution the caller
        // never stated.
        case .diagnostic: nil
        // An Activity row is the human story of the session, not of one attempt: its ordering is
        // occurrence time, and no existing row shows an attempt number.
        case .activity: nil
        }
    }

    /// Mailbox accounting for the whole envelope: the typed detail plus the fixed envelope fields.
    /// The count/byte bound covers everything an accepted envelope keeps in memory — including a
    /// screen-view row's retained JPEG, which is the largest thing the human projection carries.
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
