import Foundation

/// Readiness, not elapsed time, selects the retry budget. A never-ready socket has nothing to
/// replay, so it gets the short budget and ends the session; one lost after ready gets the long
/// budget.
public struct SocketLifecyclePolicy: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// `attempt` is 1-based across the session.
        case connecting(attempt: Int)
        case ready
        /// `attempt` is the pending retry's 1-based ordinal.
        case backingOff(attempt: Int)
        case terminal
        case stopped
    }

    public enum Action: Sendable, Equatable {
        case open(attempt: Int)
        /// `replacement` is true when an earlier socket was ready, so the caller replays.
        case ready(replacement: Bool)
        case retry(after: TimeInterval, attempt: Int)
        case terminate(ProviderFailure)
        case ignore
    }

    private let source: ProviderFailure.Source
    private let firstConnect: RetrySchedule
    private let reconnect: RetrySchedule
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

    /// Resets readiness even on a reused instance, because readiness selects the budget.
    public mutating func start() -> Action {
        retriesSpent = 0
        everReady = false
        phase = .connecting(attempt: 1)
        return .open(attempt: 1)
    }

    /// Call on the provider's config acknowledgement. An open socket alone is not readiness.
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

    /// A planned replacement, not a fault, so it opens immediately and spends no retry budget.
    public mutating func expectedRotation() -> Action {
        switch phase {
        case .terminal, .stopped: return .ignore
        case .idle, .connecting, .ready, .backingOff: break
        }
        let attempt = retriesSpent + 1
        phase = .connecting(attempt: attempt)
        return .open(attempt: attempt)
    }

    public mutating func retryElapsed() -> Action {
        guard case .backingOff(let attempt) = phase else { return .ignore }
        phase = .connecting(attempt: attempt + 1)
        return .open(attempt: attempt + 1)
    }

    public mutating func stop() {
        phase = .stopped
    }
}
