import Foundation

/// Monotonic phase timestamps for one local-CLI brain turn (`claude -p` / `codex exec`), stamped by
/// `AgentCLIProcessRunner` and `CLIBrainClient` as the turn progresses. It exists so the wire-level
/// audit can separate process startup, prompt delivery, time to first output, model completion, and
/// parsing/teardown — the sub-phases of the total `respond` latency — instead of only the total. That
/// is what lets a later warm-runtime change compare cold vs warm at the *same* boundaries.
///
/// Instants are `DispatchTime` uptime nanoseconds — a process-wide monotonic clock, so stamps taken
/// in the runner and in the client are directly comparable and immune to wall-clock adjustments.
/// Each phase is stamped at most once (the first stamp wins, so the many stdout chunks that arrive
/// for `firstStdoutByte` keep the earliest). A phase that never happens — no stdout before a
/// cancel/timeout kill, or a parse that never runs after a failure — simply stays unrecorded, so
/// `CLIBrainClient` omits the intervals that touch it rather than reporting them as zero.
///
/// `@unchecked Sendable`: the marks are shared between the pipe-drain handlers, the blocking runner
/// thread, and the client, and every access goes through the lock.
public final class AgentCLIPhaseTimings: @unchecked Sendable {
    /// The observable boundaries of a local-CLI turn, in the order they occur. Their pairwise
    /// intervals are the named phases recorded to `brain-traffic.jsonl` (see
    /// `CLIBrainClient.phaseDurationsMs`):
    ///
    /// - `runnerEntered` → `processLaunched`  = `spawnMs`  (process startup)
    /// - `processLaunched` → `stdinDelivered` = `stdinMs`  (prompt written to the child + stdin closed)
    /// - `stdinDelivered` → `firstStdoutByte` = `ttfbMs`   (time to first output — model/agent latency)
    /// - `firstStdoutByte` → `processExited`  = `outputMs` (streaming the reply to completion)
    /// - `processExited` → `replyParsed`      = `parseMs`  (reply extraction + parse + teardown)
    ///
    /// `runnerEntered` is stamped by the runner the instant it is reached (its interval from the
    /// client's `respond` entry is `queuedMs` — prompt prep + dispatch onto the runner thread).
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
    public func mark(_ phase: Phase) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock(); defer { lock.unlock() }
        if stamps[phase] == nil { stamps[phase] = now }
    }

    /// The monotonic instant a phase was observed, or nil if it never was.
    func instant(_ phase: Phase) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return stamps[phase]
    }
}
