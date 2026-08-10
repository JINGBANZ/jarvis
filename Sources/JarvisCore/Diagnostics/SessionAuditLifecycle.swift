/// Session lifecycle retained by the application composition root only.
public protocol SessionAuditLifecycle: Sendable {
    func close(deadline: Duration) async -> SessionAuditCloseResult
    /// Process-termination barrier. Live Stop uses the asynchronous close so a new Start never waits
    /// for diagnostic I/O; application Quit uses this bounded wait before the process can exit.
    func closeSynchronously(deadline: Duration) -> SessionAuditCloseResult
}
