import Foundation
import JarvisCore

/// Uptime nanoseconds, so runner and caller stamps are comparable. A phase that never happens stays
/// unrecorded, so readers omit its intervals rather than report zero.
///
/// `@unchecked Sendable`: pipe handlers, the runner thread, and the caller share the marks, and
/// every access goes through the lock.
public final class AgentCLIPhaseTimings: @unchecked Sendable {
    /// Declared in occurrence order. `firstStdoutByte` can precede `stdinDelivered`, so it is not
    /// response time to first byte.
    public enum Phase: String, CaseIterable, Sendable {
        case runnerEntered
        case processLaunched
        case stdinDelivered
        case firstStdoutByte
        case processExited
        case replyParsed
    }

    private let lock = NSLock()
    private var stamps: [Phase: UInt64] = [:]

    public init() {}

    /// The first stamp per phase wins. The stdout callback can run just outside the launch-to-exit
    /// window, so `firstStdoutByte` is clamped into it.
    public func mark(_ phase: Phase,
                     at instant: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock(); defer { lock.unlock() }
        guard stamps[phase] == nil else { return }

        if phase == .firstStdoutByte {
            var normalized = instant
            if let launched = stamps[.processLaunched] {
                normalized = max(normalized, launched)
            }
            if let exited = stamps[.processExited] {
                normalized = min(normalized, exited)
            }
            stamps[phase] = normalized
        } else {
            stamps[phase] = instant
            if let firstOutput = stamps[.firstStdoutByte] {
                if phase == .processLaunched, firstOutput < instant {
                    stamps[.firstStdoutByte] = instant
                } else if phase == .processExited, firstOutput > instant {
                    stamps[.firstStdoutByte] = instant
                }
            }
        }
    }

    func instant(_ phase: Phase) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return stamps[phase]
    }
}
