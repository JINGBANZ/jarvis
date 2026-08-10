import Foundation

/// Disk edge owned exclusively by `SessionAuditWorker`.
protocol SessionAuditWriting: Sendable {
    func openSession(at directory: URL, initialHealth: Data) throws
    func append(_ data: Data, filename: String, in directory: URL) throws
    /// Prepare the replacement privately, then consult `shouldCommit` immediately before the atomic
    /// rename. This lets close recheck its deadline after a parked filesystem write without ever
    /// exposing a stale complete marker.
    @discardableResult
    func replaceHealth(
        _ data: Data,
        in directory: URL,
        shouldCommit: @Sendable () -> Bool
    ) throws -> Bool
}
