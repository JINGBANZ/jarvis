import Foundation
import JarvisCore

/// Synchronous process ownership shared by runtime actors and their leased conversations.
///
/// Actor teardown cannot be awaited from `deinit`; this lock-guarded registry gives Stop and final
/// owner release an immediate, nonisolated kill path.
///
/// A process may carry exit work, which runs only once the terminated process has actually exited.
/// Codex writes its `CODEX_HOME` until it has exited, so a home removed at the signal came back with
/// default permissions and Codex's cache in it. `drained()` is how Stop waits for that work instead
/// of racing it.
final class AgentRuntimeLifetime: @unchecked Sendable {
    private struct Owned {
        let process: AgentRuntimeProcess
        let afterExit: (@Sendable () -> Void)?
    }

    /// Beyond the process's own SIGTERM-to-SIGKILL grace. Only a lost exit notification reaches it,
    /// and the exit work then runs anyway rather than leaving its files behind for good.
    private static let exitWaitSeconds: TimeInterval = 3

    private let lock = NSLock()
    private var owned: [ObjectIdentifier: Owned] = [:]
    private var terminated = false
    private let exits = DispatchGroup()

    deinit {
        terminateAll()
    }

    func register(
        _ process: AgentRuntimeProcess,
        afterExit: (@Sendable () -> Void)? = nil
    ) throws {
        let entry = Owned(process: process, afterExit: afterExit)
        lock.lock()
        guard !terminated else {
            lock.unlock()
            Self.retire(entry, tracking: exits)
            throw CancellationError()
        }
        owned[ObjectIdentifier(process)] = entry
        lock.unlock()
    }

    /// Terminate one owned process and run its exit work once it has exited. A process this lifetime
    /// already let go of is only signaled again, so exit work never runs twice.
    func terminate(_ process: AgentRuntimeProcess) {
        lock.lock()
        let entry = owned.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
        if let entry {
            Self.retire(entry, tracking: exits)
        } else {
            process.terminateNow()
        }
    }

    func terminateAll() {
        lock.lock()
        guard !terminated else {
            lock.unlock()
            return
        }
        terminated = true
        let entries = Array(owned.values)
        owned.removeAll()
        lock.unlock()
        for entry in entries {
            Self.retire(entry, tracking: exits)
        }
    }

    /// Returns once every process terminated so far has exited and its exit work has run.
    func drained() async {
        let exits = self.exits
        await withCheckedContinuation { continuation in
            exits.notify(queue: .global(qos: .utility)) {
                continuation.resume()
            }
        }
    }

    /// Static so `deinit` never hands `self` to the waiter. The waiter holds the process until it
    /// exits, which keeps the process's own exit monitor able to record that exit.
    private static func retire(_ entry: Owned, tracking exits: DispatchGroup) {
        entry.process.terminateNow()
        exits.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = entry.process.waitForExit(until: Date().addingTimeInterval(exitWaitSeconds))
            entry.afterExit?()
            exits.leave()
        }
    }
}
