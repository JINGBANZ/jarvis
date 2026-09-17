import Foundation

/// Repeated signals within an incident never restore its budget; only `succeeded()` or `reset()`
/// do.
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

    /// False once exhausted or stopped.
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

    /// Returns `.exhausted` exactly once; later calls return `.ignore`.
    public mutating func failed() -> FailureAction {
        guard state == .active else { return .ignore }
        guard let delay = schedule.delay(forRetry: nextRetry) else {
            state = .exhausted
            return .exhausted
        }
        nextRetry += 1
        return .retry(attempt: nextRetry, maximum: schedule.maximumRetries, delay: delay)
    }

    public mutating func succeeded() {
        guard state != .stopped else { return }
        state = .idle
        nextRetry = 0
    }

    public mutating func stop() {
        state = .stopped
    }

    public mutating func reset() {
        state = .idle
        nextRetry = 0
    }
}
