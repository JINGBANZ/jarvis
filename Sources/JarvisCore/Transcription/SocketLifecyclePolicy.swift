import Foundation

/// The socket state machine both WebSocket transcribers drive: when to open, when a socket counts as
/// ready, which failures terminate now, and how much retry budget is left.
///
/// Foundation-only, so the decisions are unit-tested rather than only observable against a live
/// endpoint. The App driver owns the `URLSession`, the timers, and the lock, and asks this for every
/// decision; nothing here knows a socket exists.
///
/// Readiness, not elapsed time, selects the budget. A socket that has never been acknowledged has
/// nothing buffered to preserve and every attempt is silence the user cannot explain, so it gets a
/// short budget and ends the session with the cause. A socket lost after it was working has a
/// session's audio to replay into a replacement, so it gets the long one and degrades rather than
/// ending everything.
public struct SocketLifecyclePolicy: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// A socket is open or opening; `attempt` is 1-based across this session.
        case connecting(attempt: Int)
        /// The provider acknowledged the session configuration.
        case ready
        /// Waiting out a retry delay; `attempt` is the pending retry's 1-based ordinal.
        case backingOff(attempt: Int)
        /// A failure ended this endpoint. Every later event is ignored.
        case terminal
        /// The user stopped. Every later event is ignored.
        case stopped
    }

    public enum Action: Sendable, Equatable {
        /// Open socket number `attempt`.
        case open(attempt: Int)
        /// The socket is usable. `replacement` is true when an earlier socket was already ready, so
        /// the caller knows to replay rather than start fresh.
        case ready(replacement: Bool)
        case retry(after: TimeInterval, attempt: Int)
        case terminate(ProviderFailure)
        /// A late callback from a replaced socket, or an event after stop. Do nothing.
        case ignore
    }

    private let source: ProviderFailure.Source
    private let firstConnect: RetrySchedule
    private let reconnect: RetrySchedule
    /// Retries spent since the last acknowledgement.
    private var retriesSpent = 0

    public private(set) var phase: Phase = .idle
    public private(set) var everReady = false

    public init(
        source: ProviderFailure.Source, firstConnect: RetrySchedule, reconnect: RetrySchedule
    ) {
        self.source = source
        self.firstConnect = firstConnect
        self.reconnect = reconnect
    }

    /// Begin a session. A fresh session is always never-ready, even on an instance that ran one
    /// before, because readiness selects the budget and how an exhausted budget is categorized.
    public mutating func start() -> Action {
        retriesSpent = 0
        everReady = false
        phase = .connecting(attempt: 1)
        return .open(attempt: 1)
    }

    /// The provider acknowledged the session configuration. An open socket alone is not readiness.
    public mutating func acknowledged() -> Action {
        guard case .connecting = phase else { return .ignore }
        let replacement = everReady
        everReady = true
        retriesSpent = 0
        phase = .ready
        return .ready(replacement: replacement)
    }

    public mutating func failed(_ cause: ProviderFailure) -> Action {
        switch phase {
        case .terminal, .stopped: return .ignore
        case .idle, .connecting, .ready, .backingOff: break
        }
        if cause.disposition == .permanent {
            phase = .terminal
            return .terminate(cause)
        }
        let schedule = everReady ? reconnect : firstConnect
        guard let delay = schedule.delay(forRetry: retriesSpent) else {
            phase = .terminal
            return .terminate(.exhausted(last: cause, source: source, everReady: everReady))
        }
        retriesSpent += 1
        phase = .backingOff(attempt: retriesSpent)
        return .retry(after: delay, attempt: retriesSpent)
    }

    /// The server warned this socket is going away. Replacing it is the plan, not a fault, so it
    /// opens immediately and spends no retry budget.
    public mutating func expectedRotation() -> Action {
        switch phase {
        case .terminal, .stopped: return .ignore
        case .idle, .connecting, .ready, .backingOff: break
        }
        let attempt = retriesSpent + 1
        phase = .connecting(attempt: attempt)
        return .open(attempt: attempt)
    }

    /// The backoff delay elapsed.
    public mutating func retryElapsed() -> Action {
        guard case .backingOff(let attempt) = phase else { return .ignore }
        phase = .connecting(attempt: attempt + 1)
        return .open(attempt: attempt + 1)
    }

    public mutating func stop() {
        phase = .stopped
    }
}
