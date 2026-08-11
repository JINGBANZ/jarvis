/// Whether the session audit closed with or without known evidence loss.
public enum SessionAuditCloseResult: Sendable, Equatable {
    case complete
    case partial
}
