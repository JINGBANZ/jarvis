import Foundation

/// Provider-neutral attribution for one request inside a coaching attempt.
public struct CoachingRequestContext: Sendable {
    public let attemptID: Int
    public let trigger: String
    public let sourceTrigger: String
    public let phase: CoachingAttemptAuditEvent.RequestPhase
    public let sequence: Int

    var approximateRetainedBytes: Int {
        96 + trigger.utf8.count + sourceTrigger.utf8.count
    }
}

/// The task-local scope is part of the neutral audit boundary, not a concrete file recorder.
enum CoachingRequestAttribution {
    @TaskLocal static var current: CoachingRequestContext?

    static func context(
        attemptID: Int,
        wake: CoachingAttemptAuditEvent.Wake,
        reason: TriggerReason,
        phase: CoachingAttemptAuditEvent.RequestPhase,
        sequence: Int
    ) -> CoachingRequestContext {
        let source = triggerName(reason)
        return CoachingRequestContext(
            attemptID: attemptID,
            trigger: wake == .pendingWork ? CoachingAttemptAuditEvent.Wake.pendingWork.rawValue : source,
            sourceTrigger: source,
            phase: phase,
            sequence: sequence)
    }

    static func triggerName(_ reason: TriggerReason) -> String {
        switch reason {
        case .turnEnd: "turn_end"
        case .silence: "silence"
        case .manualHint: "manual_hint"
        }
    }
}
