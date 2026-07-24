import Foundation

/// A bounded exponential retry schedule shared by long-lived runtime infrastructure. The caller
/// owns the work and lifecycle; this type only makes "temporary failure gets retries before a
/// terminal consequence" a small, deterministic, unit-tested rule.
public struct RetrySchedule: Sendable, Equatable {
    public let maximumRetries: Int
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval

    public init(maximumRetries: Int, initialDelay: TimeInterval, maximumDelay: TimeInterval) {
        precondition(maximumRetries >= 0)
        precondition(initialDelay >= 0)
        precondition(maximumDelay >= initialDelay)
        self.maximumRetries = maximumRetries
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
    }

    /// Delay before a zero-based retry, or nil once the budget is exhausted.
    public func delay(forRetry retry: Int) -> TimeInterval? {
        guard retry >= 0, retry < maximumRetries else { return nil }
        return min(initialDelay * pow(2, Double(retry)), maximumDelay)
    }
}
