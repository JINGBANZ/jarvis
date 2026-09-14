import Foundation

/// Session health survives failed cycle budgets; only successful coaching resets the streak.
struct BrainCycleRecovery {
    /// How long a streak of failed cycles may last before the session ends. The clock starts at the
    /// streak's first failed cycle, not at the last success: a quiet stretch with no coaching is not
    /// an outage, so it must not end the session on the first failure that follows it.
    static let ceiling: TimeInterval = 600

    /// Consecutive failed cycles since the last success.
    struct Streak {
        let startedAt: TimeInterval
        var cycles: Int
        /// The most recent cycle's cause, which the ceiling's session end reports.
        var lastFailure: ProviderFailure
    }

    private(set) var streak: Streak?
    private(set) var nextCycleAt: TimeInterval = 0
    private(set) var permanentFailures: [BrainTarget: ProviderFailure] = [:]

    mutating func markPermanent(_ target: BrainTarget, failure: ProviderFailure) { permanentFailures[target] = failure }

    mutating func fail(at now: TimeInterval, failure: ProviderFailure) {
        let delays: [TimeInterval] = [0, 5, 15, 45, 120]
        let previousCycles = streak?.cycles ?? 0
        nextCycleAt = now + delays[min(previousCycles, delays.count - 1)]
        streak = Streak(
            startedAt: streak?.startedAt ?? now, cycles: previousCycles + 1, lastFailure: failure)
    }

    mutating func succeed() {
        streak = nil
        nextCycleAt = 0
    }

    /// Seconds before the current streak reaches the ceiling; infinite while no cycle has failed.
    func remainingBeforeCeiling(at now: TimeInterval) -> TimeInterval {
        guard let streak else { return .infinity }
        return max(0, streak.startedAt + Self.ceiling - now)
    }

    func ceilingReached(at now: TimeInterval) -> Bool {
        remainingBeforeCeiling(at: now) == 0
    }
}
