import Foundation

/// Synchronous process ownership shared by runtime actors and their leased conversations.
///
/// Actor teardown cannot be awaited from `deinit`; this lock-guarded registry gives Stop and final
/// owner release an immediate, nonisolated kill path.
final class AgentRuntimeLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: AgentRuntimeProcess] = [:]
    private var terminated = false

    deinit {
        terminateAll()
    }

    func register(_ process: AgentRuntimeProcess) throws {
        lock.lock()
        guard !terminated else {
            lock.unlock()
            process.terminateNow()
            throw CancellationError()
        }
        processes[ObjectIdentifier(process)] = process
        lock.unlock()
    }

    func unregister(_ process: AgentRuntimeProcess) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        guard !terminated else {
            lock.unlock()
            return
        }
        terminated = true
        let owned = Array(processes.values)
        processes.removeAll()
        lock.unlock()
        for process in owned {
            process.terminateNow()
        }
    }
}
