import Foundation
import JarvisCore

/// Monotonic phase timestamps for one explicit agentic-evaluation CLI invocation, stamped by
/// `AgentCLIProcessRunner` as it progresses. Coaching no longer uses this one-shot runner; its
/// persistent runtimes record their own semantic turn boundaries.
///
/// Instants are `DispatchTime` uptime nanoseconds — a process-wide monotonic clock, so stamps taken
/// in the runner and in the client are directly comparable and immune to wall-clock adjustments.
/// Each phase is stamped at most once (the first stamp wins, so the many stdout chunks that arrive
/// for `firstStdoutByte` keep the earliest). A phase that never happens — no stdout before a
/// cancel/timeout kill, or a parse that never runs after a failure — simply stays unrecorded, so
/// `CLIBrainClient` omits the intervals that touch it rather than reporting them as zero. Scheduler
/// timing can run the stdout callback just before `Process.run()` returns or after `waitUntilExit`
/// observes the exit; that observation is clamped into the known launched-through-exited window.
///
/// `@unchecked Sendable`: the marks are shared between the pipe-drain handlers, the blocking runner
/// thread, and the client, and every access goes through the lock.
public final class AgentCLIPhaseTimings: @unchecked Sendable {
    /// The observable boundaries of a local-CLI turn, in the order they occur. Their pairwise
    /// intervals describe the evaluator invocation:
    ///
    /// - `runnerEntered` → `processLaunched`  = `spawnMs`  (process startup)
    /// - `processLaunched` → `stdinDelivered` = `stdinMs`  (prompt written to the child + stdin closed)
    /// - `processLaunched` → `firstStdoutByte` = `firstOutputMs` (first arbitrary CLI stdout; startup
    ///   and progress events count and can precede stdin delivery, so this is not response TTFB)
    /// - `firstStdoutByte` → `processExited`  = `outputMs` (remaining CLI output through process exit)
    /// - `processExited` → `replyParsed`      = `parseMs`  (final reply extraction + protocol parse)
    ///
    /// `runnerEntered` is stamped by the runner the instant it is reached.
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

    /// Stamp `phase` at the current monotonic instant, keeping the earliest stamp for a phase marked
    /// more than once.
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

    /// The monotonic instant a phase was observed, or nil if it never was.
    func instant(_ phase: Phase) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return stamps[phase]
    }
}
