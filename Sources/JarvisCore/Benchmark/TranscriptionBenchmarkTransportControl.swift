import Foundation

/// Process-local fault controller used only by the explicit reconnect benchmark.
///
/// It can hold one replacement connection while synthetic audio fills the real replay buffer. The
/// active transcriber installs the scoped interruption operation; no host network state is changed.
/// `@unchecked Sendable`: `lock` protects the handler, hold state, and deferred reconnect operation.
public final class TranscriptionBenchmarkTransportControl: @unchecked Sendable {
    private let lock = NSLock()
    private var interruption: (@Sendable () -> Bool)?
    private var interruptionHeld = false
    private var deferredReconnect: (@Sendable () -> Void)?

    public init() {}

    public func installInterruption(_ operation: @escaping @Sendable () -> Bool) {
        lock.lock()
        interruption = operation
        interruptionHeld = false
        deferredReconnect = nil
        lock.unlock()
    }

    public func uninstallInterruption() {
        lock.lock()
        interruption = nil
        interruptionHeld = false
        deferredReconnect = nil
        lock.unlock()
    }

    @discardableResult
    public func beginInterruption() -> Bool {
        lock.lock()
        guard !interruptionHeld, let interruption else {
            lock.unlock()
            return false
        }
        interruptionHeld = true
        lock.unlock()

        guard interruption() else {
            lock.lock()
            interruptionHeld = false
            deferredReconnect = nil
            lock.unlock()
            return false
        }
        return true
    }

    public func runReconnectWhenReleased(_ operation: @escaping @Sendable () -> Void) {
        lock.lock()
        guard interruption != nil else {
            lock.unlock()
            return
        }
        if interruptionHeld {
            if deferredReconnect == nil { deferredReconnect = operation }
            lock.unlock()
            return
        }
        lock.unlock()
        operation()
    }

    public func endInterruption() {
        lock.lock()
        guard interruption != nil else {
            lock.unlock()
            return
        }
        interruptionHeld = false
        let reconnect = deferredReconnect
        deferredReconnect = nil
        lock.unlock()
        reconnect?()
    }
}
