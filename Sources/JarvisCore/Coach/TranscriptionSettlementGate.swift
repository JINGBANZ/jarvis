import Foundation

/// @unchecked Sendable: `lock` guards all mutable state, and continuations are removed under it
/// before they are resumed.
final class TranscriptionSettlementGate: @unchecked Sendable {
    private let lock = NSLock()
    private struct Waiter {
        let through: TimeInterval?
        let continuation: CheckedContinuation<Void, Never>
    }

    private var workBySpeaker: [Speaker: TranscriptionWorkState] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var interruptGeneration: UInt = 0

    func update(_ state: TranscriptionWorkState, for speaker: Speaker) {
        let continuations: [CheckedContinuation<Void, Never>]
        lock.lock()
        workBySpeaker[speaker] = state == .settled ? nil : state
        let ready = waiters.filter { permitsCoachingLocked(through: $0.value.through) }
        continuations = ready.values.map(\.continuation)
        for id in ready.keys { waiters.removeValue(forKey: id) }
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func permitsCoaching(through spokenAt: TimeInterval?) -> Bool {
        lock.withLock { permitsCoachingLocked(through: spokenAt) }
    }

    private func permitsCoachingLocked(through spokenAt: TimeInterval?) -> Bool {
        workBySpeaker.values.allSatisfy { $0.permitsCoaching(through: spokenAt) }
    }

    /// Wakes current waiters only; later waiters still see unsettled work.
    func interruptWaiters() {
        let continuations: [CheckedContinuation<Void, Never>]
        lock.lock()
        interruptGeneration &+= 1
        continuations = waiters.values.map(\.continuation)
        waiters.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func interruptGenerationSnapshot() -> UInt {
        lock.withLock { interruptGeneration }
    }

    /// Returns at once if interrupted after `generation`, which closes the lost-wakeup window.
    func waitUntilSettled(
        through spokenAt: TimeInterval? = nil,
        unlessInterruptedAfter generation: UInt
    ) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if permitsCoachingLocked(through: spokenAt) || Task.isCancelled
                    || interruptGeneration != generation {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters[id] = Waiter(through: spokenAt, continuation: continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Never>?
            self.lock.lock()
            continuation = self.waiters.removeValue(forKey: id)?.continuation
            self.lock.unlock()
            continuation?.resume()
        }
    }
}
