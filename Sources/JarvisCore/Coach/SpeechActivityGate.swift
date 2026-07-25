import Foundation

/// A small synchronous bridge from Realtime VAD callbacks to the asynchronous pending-attempt
/// scheduler. The scheduler suspends without polling while either conversation side is speaking.
///
/// `@unchecked Sendable` is safe because `lock` guards all mutable state (`activeSpeakers` and
/// `waiters`), and continuations are removed under that lock before they are resumed.
final class SpeechActivityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeSpeakers: Set<Speaker> = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var interruptGeneration: UInt = 0

    func setActive(_ isActive: Bool, for speaker: Speaker) {
        let continuations: [CheckedContinuation<Void, Never>]
        lock.lock()
        if isActive {
            activeSpeakers.insert(speaker)
        } else {
            activeSpeakers.remove(speaker)
        }
        if activeSpeakers.isEmpty {
            continuations = Array(waiters.values)
            waiters.removeAll()
        } else {
            continuations = []
        }
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    /// Wake the attempts currently parked on speech without changing the tracked activity state.
    ///
    /// An explicit manual hint uses this interruption boundary. A later automatic attempt still
    /// observes the unchanged active-speaker set and waits normally.
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

    /// Wait for inactive speech unless an explicit interruption occurred after `generation`.
    ///
    /// Comparing the generation while registering closes the lost-wakeup window where a manual
    /// hint arrives after the caller checks pending triggers but before this continuation exists.
    func waitUntilInactive(unlessInterruptedAfter generation: UInt) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if activeSpeakers.isEmpty || Task.isCancelled
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
