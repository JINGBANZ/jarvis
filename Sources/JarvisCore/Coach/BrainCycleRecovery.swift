import Foundation

struct BrainCycleRecovery {
    /// Seconds from the streak's first failure, not the last success: quiet time is not an outage.
    static let ceiling: TimeInterval = 600

    struct Streak {
        let startedAt: TimeInterval
        var cycles: Int
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

    /// Infinite while no cycle has failed.
    func remainingBeforeCeiling(at now: TimeInterval) -> TimeInterval {
        guard let streak else { return .infinity }
        return max(0, streak.startedAt + Self.ceiling - now)
    }

    func ceilingReached(at now: TimeInterval) -> Bool {
        remainingBeforeCeiling(at: now) == 0
    }
}
