/// No-op audit implementation for compositions that do not retain session evidence.
public final class DisabledSessionAudit: BrainTrafficAuditing, CoachingAttemptAuditing,
    SessionAuditLifecycle, Sendable {
    public init() {}

    public func record(_ event: BrainTrafficAuditEvent) {}

    public func record(_ event: CoachingAttemptAuditEvent) {}

    public func close(deadline: Duration) async -> SessionAuditCloseResult {
        .disabled
    }
}
