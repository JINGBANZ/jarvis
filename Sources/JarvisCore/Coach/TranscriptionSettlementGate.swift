import Foundation

/// A synchronous bridge from provider transcription state to automatic coaching admission.
/// Automatic attempts suspend without polling while either side owns unfinished transcription work.
///
/// `@unchecked Sendable` is safe because `lock` guards all mutable state, and continuations are
/// removed under that lock before they are resumed.
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

    /// Wake the attempts currently parked on transcription without changing provider state.
    /// A manual hint uses this explicit exception; later automatic attempts still see unsettled work.
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

    /// Wait until both providers are settled unless an explicit interruption occurred after the
    /// supplied generation. The generation comparison closes the manual-hint lost-wakeup window.
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
