import Foundation

/// @unchecked Sendable: `lock` guards all mutable state, and continuations are removed under it
/// before they are resumed.
final class TranscriptionSettlementGate: @unchecked Sendable {
    private let lock = NSLock()
    private var unsettledSpeakers: Set<Speaker> = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var interruptGeneration: UInt = 0

    func setUnsettled(_ isUnsettled: Bool, for speaker: Speaker) {
        let continuations: [CheckedContinuation<Void, Never>]
        lock.lock()
        if isUnsettled {
            unsettledSpeakers.insert(speaker)
        } else {
            unsettledSpeakers.remove(speaker)
        }
        if unsettledSpeakers.isEmpty {
            continuations = Array(waiters.values)
            waiters.removeAll()
        } else {
            continuations = []
        }
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    /// Wakes current waiters only; later waiters still see unsettled work.
    func interruptWaiters() {
        let continuations: [CheckedContinuation<Void, Never>]
        lock.lock()
        interruptGeneration &+= 1
        continuations = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func interruptGenerationSnapshot() -> UInt {
        lock.withLock { interruptGeneration }
    }

    /// Returns at once if interrupted after `generation`, which closes the lost-wakeup window.
    func waitUntilSettled(unlessInterruptedAfter generation: UInt) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if unsettledSpeakers.isEmpty || Task.isCancelled
                    || interruptGeneration != generation {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Never>?
            self.lock.lock()
            continuation = self.waiters.removeValue(forKey: id)
            self.lock.unlock()
            continuation?.resume()
        }
    }
}
