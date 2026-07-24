import Foundation

/// State for one bounded temporary-failure incident. Repeated signals may accelerate the next
/// attempt, but cannot reset its budget; only a successful recovery starts a fresh future incident.
public struct RetryIncident: Sendable {
    public enum FailureAction: Sendable, Equatable {
        case retry(attempt: Int, maximum: Int, delay: TimeInterval)
        case exhausted
        case ignore
    }

    private enum State: Sendable {
        case idle
        case active
        case exhausted
        case stopped
    }

    private let schedule: RetrySchedule
    private var state = State.idle
    private var nextRetry = 0

    public init(schedule: RetrySchedule) {
        self.schedule = schedule
    }

    /// Start an incident or join the one already in progress. False means exhaustion or explicit
    /// teardown already made later signals irrelevant.
    public mutating func beginOrContinue() -> Bool {
        switch state {
        case .idle:
            state = .active
            nextRetry = 0
            return true
        case .active:
            return true
        case .exhausted, .stopped:
            return false
        }
    }

    /// Consume one failure. Exhaustion is emitted exactly once; all later callbacks are ignored.
    public mutating func failed() -> FailureAction {
        guard state == .active else { return .ignore }
        guard let delay = schedule.delay(forRetry: nextRetry) else {
            state = .exhausted
            return .exhausted
        }
        nextRetry += 1
        return .retry(attempt: nextRetry, maximum: schedule.maximumRetries, delay: delay)
    }

    /// A successful rebuild closes the incident and restores a full budget for a later route change.
    public mutating func succeeded() {
        guard state != .stopped else { return }
        state = .idle
        nextRetry = 0
    }

    /// Permanently suppress work retained by callbacks from a capture that has been stopped.
    public mutating func stop() {
        state = .stopped
    }

    /// Prepare a retained owner for a new lifecycle.
    public mutating func reset() {
        state = .idle
        nextRetry = 0
    }
}
