import Foundation

/// One host-proven reason to stop an otherwise healthy agent CLI before its normal final reply.
///
/// This is deliberately separate from task cancellation: cancellation means the user stopped or
/// superseded the work and must still fail the request, while a completion signal says the caller
/// already received the run's authoritative result through another transport.
public final class AgentCLICompletionSignal: @unchecked Sendable {
    public enum Reason: String, Sendable, Equatable {
        case terminalActionDelivered
    }

    final class Observation: @unchecked Sendable {
        private weak var signal: AgentCLICompletionSignal?
        private let id: UUID?
        private let lock = NSLock()
        private var isCancelled = false

        fileprivate init(signal: AgentCLICompletionSignal?, id: UUID?) {
            self.signal = signal
            self.id = id
        }

        deinit {
            cancel()
        }

        func cancel() {
            lock.lock()
            guard !isCancelled else {
                lock.unlock()
                return
            }
            isCancelled = true
            let signal = self.signal
            let id = self.id
            self.signal = nil
            lock.unlock()

            if let id {
                signal?.removeObservation(id)
            }
        }
    }

    private let lock = NSLock()
    private var completedReason: Reason?
    private var observers: [UUID: @Sendable (Reason) -> Void] = [:]

    public init() {}

    /// Completes the signal exactly once. The first reason wins.
    @discardableResult
    public func signal(_ reason: Reason) -> Bool {
        let callbacks: [@Sendable (Reason) -> Void]
        lock.lock()
        guard completedReason == nil else {
            lock.unlock()
            return false
        }
        completedReason = reason
        callbacks = Array(observers.values)
        observers.removeAll()
        lock.unlock()

        callbacks.forEach { $0(reason) }
        return true
    }

    public var reason: Reason? {
        lock.lock()
        defer { lock.unlock() }
        return completedReason
    }

    /// Installs a runner-local wakeup. A completion that won before registration is delivered
    /// synchronously, while cancelling the observation makes every later completion harmless.
    func observe(
        _ callback: @escaping @Sendable (Reason) -> Void
    ) -> Observation {
        let id = UUID()
        let immediateReason: Reason?
        lock.lock()
        if let completedReason {
            immediateReason = completedReason
        } else {
            observers[id] = callback
            immediateReason = nil
        }
        lock.unlock()

        if let immediateReason {
            callback(immediateReason)
            return Observation(signal: nil, id: nil)
        }
        return Observation(signal: self, id: id)
    }

    private func removeObservation(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }
}
