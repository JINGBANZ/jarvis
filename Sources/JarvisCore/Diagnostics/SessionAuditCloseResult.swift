/// Whether the session audit durably completed before its close deadline.
public enum SessionAuditCloseResult: Sendable, Equatable {
    case complete
    case partial
}
