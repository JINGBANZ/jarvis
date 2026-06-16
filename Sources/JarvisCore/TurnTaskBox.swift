import Foundation

/// Tracks the unstructured Tasks spawned per transcription trigger so Stop can cancel an in-flight
/// coaching turn. Fresh-speech handling is no longer done by cancelling here — CoachDriver coalesces
/// concurrent triggers into the running turn — so this just spawns and tracks, and cancels everything
/// on Stop. `@unchecked Sendable`: all access to `tasks` is guarded by the lock.
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

    public func cancelAll() {
        lock.lock(); let snapshot = tasks; tasks.removeAll(); lock.unlock()
        snapshot.forEach { $0.cancel() }
    }
}
