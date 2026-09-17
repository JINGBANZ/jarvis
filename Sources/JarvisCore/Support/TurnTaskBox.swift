import Foundation

/// `@unchecked Sendable`: all access to `tasks` is guarded by the lock.
public final class TurnTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    public init() {}

    public func run(_ op: @escaping @Sendable () async -> Void) {
        lock.lock()
        tasks.removeAll { $0.isCancelled }
        tasks.append(Task { await op() })
        lock.unlock()
    }

    /// Cancelling only requests a stop; tasks still write session logs while unwinding. Await the
    /// returned tasks when the session's files must be complete.
    @discardableResult
    public func cancelAll() -> [Task<Void, Never>] {
        lock.lock(); let snapshot = tasks; tasks.removeAll(); lock.unlock()
        snapshot.forEach { $0.cancel() }
        return snapshot
    }
}
