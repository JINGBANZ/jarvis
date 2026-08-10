/// Session lifecycle retained by the application composition root only.
public protocol SessionAuditLifecycle: Sendable {
    func close(deadline: Duration) async -> SessionAuditCloseResult
    func waitForPersistenceToStop() async
}
