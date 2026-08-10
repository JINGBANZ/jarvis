import Foundation

/// Disk edge owned exclusively by `SessionAuditWorker`.
protocol SessionAuditWriting: Sendable {
    func openSession(at directory: URL, initialHealth: Data) throws
    func append(_ data: Data, filename: String, in directory: URL) throws
    /// Prepare the replacement privately, then consult `shouldCommit` immediately before and after
    /// the atomic rename. This lets close reject a complete marker when either preparation or the
    /// commit itself crosses its deadline, then replace it with partial evidence.
    @discardableResult
    func replaceHealth(
        _ data: Data,
        in directory: URL,
        shouldCommit: @Sendable () -> Bool
    ) throws -> Bool
    /// Remove a marker that can no longer be trusted. A missing marker is evaluator-visible partial
    /// evidence, so this is the safe fallback when a corrective replacement cannot be persisted.
    func invalidateHealth(in directory: URL) throws
}
