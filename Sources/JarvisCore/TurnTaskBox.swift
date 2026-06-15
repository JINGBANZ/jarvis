import Foundation

/// Tracks the unstructured Tasks spawned per transcription trigger so Stop can cancel an in-flight
/// coaching turn, and so fresh user speech can replace a now-stale turn.
///
/// `cancelPrevious` makes the replacement DETERMINISTIC: cancelling a Task is cooperative, so a
/// predecessor parked in `await brain.respond` doesn't unwind synchronously and would still hold the
/// driver's single in-flight slot — the replacement would then be dropped as `.busy`, killing the old
/// turn AND the new one. To avoid that, the replacement first `await`s the cancelled predecessor's
/// completion (it returns quickly once cancellation is observed), so the slot is free before the new
/// turn runs. `@unchecked Sendable`: all access to `tasks`/`latest` is guarded by the lock.
public final class TurnTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var latest: Task<Void, Never>?

    public init() {}

    public func run(cancelPrevious: Bool = false, _ op: @escaping @Sendable () async -> Void) {
        lock.lock()
        let predecessor = latest
        if cancelPrevious {
            // Fresh user speech makes any in-flight turn stale — cancel it so the new context wins.
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
        }
        tasks.removeAll { $0.isCancelled }
        let task = Task {
            // Wait for the cancelled predecessor to release the single in-flight slot before running,
            // otherwise this replacement would be dropped as `.busy`.
            if cancelPrevious { await predecessor?.value }
            await op()
        }
        tasks.append(task)
        latest = task
        lock.unlock()
    }

    public func cancelAll() {
        lock.lock(); let snapshot = tasks; tasks.removeAll(); latest = nil; lock.unlock()
        snapshot.forEach { $0.cancel() }
    }
}
