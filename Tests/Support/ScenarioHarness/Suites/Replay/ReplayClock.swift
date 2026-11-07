#if JARVIS_LIVE_E2E
import Foundation
import JarvisCore

/// @unchecked: all reads and writes of session time are protected by the lock.
final class ReplayClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 0
    func now() -> TimeInterval { lock.withLock { time } }
    func advance(to value: Double) { lock.withLock { time = max(time, value) } }
}

#endif
