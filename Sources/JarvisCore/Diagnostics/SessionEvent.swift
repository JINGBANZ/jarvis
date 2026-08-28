import Foundation

/// The one versioned envelope for a session-evidence occurrence.
///
/// Phase 1 expand step of the lean coaching core ("One Event, Two Projections" in
/// wiki/lean-coaching-core.md): every occurrence admitted to the shared bounded session-evidence
/// transport travels as one `SessionEvent`. The narrow producer ports — `BrainTrafficAuditing` and
/// `CoachingAttemptAuditing` — remain typed views that wrap their detail into this envelope on the
/// one per-session handle; they are not separate queues, workers, health records, or lifecycles.
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
    }

    /// The full typed payload of one occurrence. Later slices add cases here — a new producer
    /// category joins the envelope, never a second admission stack.
    public enum Detail: Sendable {
        case brainTraffic(BrainTrafficAuditEvent)
        case coachingAttempt(CoachingAttemptAuditEvent)
    }

    public let version: Int
    /// Identity of the originating session handle. Every event is stamped at admission so late
    /// work from a closing session can never be attributed to its replacement.
    public let sessionID: UUID
    /// When the producer handed the occurrence to the transport. The occurrence itself is
    /// timestamped by `occurredAt`.
    public let recordedAt: Date
    public let detail: Detail
    /// Closed human-safe copy for the Activity projection. `ActivityLog.Event` is the existing
    /// closed presentation set, reused so the shared stack never opens a generic path for
    /// producers to author human-facing strings. Unused until Phase 2 migrates Activity onto the
    /// envelope: no persisted projection reads this field today.
    public let activityPresentation: ActivityLog.Event?

    public init(
        sessionID: UUID,
        detail: Detail,
        activityPresentation: ActivityLog.Event? = nil,
        recordedAt: Date = Date()
    ) {
        self.version = Self.currentVersion
        self.sessionID = sessionID
        self.detail = detail
        self.activityPresentation = activityPresentation
        self.recordedAt = recordedAt
    }

    /// Derived from `detail` so the stable kind can never disagree with the typed payload.
    public var kind: Kind {
        switch detail {
        case .brainTraffic: .brainTraffic
        case .coachingAttempt: .coachingAttempt
        }
    }

    /// When the occurrence happened, as its typed detail recorded it. Derived rather than stored
    /// twice so envelope timing cannot drift from what the persisted record encodes.
    public var occurredAt: Date {
        switch detail {
        case .brainTraffic(let event): event.date
        case .coachingAttempt(.started(let event)): event.date
        case .coachingAttempt(.finished(let event)): event.date
        }
    }

    /// Attempt attribution where applicable: nil for traffic outside a coaching attempt, such as
    /// the summarizer. Derived from the detail's own attribution for the same no-drift reason.
    public var attemptID: Int? {
        switch detail {
        case .brainTraffic(let event): event.requestContext?.attemptID
        case .coachingAttempt(.started(let event)): event.attemptID
        case .coachingAttempt(.finished(let event)): event.attemptID
        }
    }

    /// Mailbox accounting for the whole envelope: the typed detail, the fixed envelope fields, and
    /// the retained strings of an attached Activity presentation. The count/byte bound covers
    /// everything an accepted envelope keeps in memory.
    var approximateRetainedBytes: Int {
        var bytes = 64
        switch detail {
        case .brainTraffic(let event):
            bytes = Self.adding(bytes, event.approximateRetainedBytes)
        case .coachingAttempt(let event):
            bytes = Self.adding(bytes, event.approximateRetainedBytes)
        }
        if let activityPresentation {
            let rendered = activityPresentation.rendered
            bytes = Self.adding(bytes, rendered.message.utf8.count)
            bytes = Self.adding(bytes, rendered.imageBase64?.utf8.count ?? 0)
        }
        return bytes
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
