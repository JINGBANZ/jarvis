import Foundation

/// A small synchronous bridge from Realtime VAD callbacks to the asynchronous pending-attempt
/// scheduler. The scheduler suspends without polling while either conversation side is speaking.
final class SpeechActivityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeSpeakers: Set<Speaker> = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

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

    func waitUntilInactive() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if activeSpeakers.isEmpty || Task.isCancelled {
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
