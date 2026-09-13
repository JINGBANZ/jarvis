import Foundation

/// Session health survives failed cycle budgets; only successful coaching resets the streak.
struct BrainCycleRecovery {
    private(set) var failedCycles = 0
    private(set) var lastSuccess: TimeInterval
    private(set) var nextCycleAt: TimeInterval = 0
    private(set) var permanentFailures: [BrainTarget: ProviderFailure] = [:]

    init(startedAt: TimeInterval) { lastSuccess = startedAt }

    mutating func markPermanent(_ target: BrainTarget, failure: ProviderFailure) { permanentFailures[target] = failure }

    mutating func fail(at now: TimeInterval) {
        let delays: [TimeInterval] = [0, 5, 15, 45, 120]
        nextCycleAt = now + delays[min(failedCycles, delays.count - 1)]
        failedCycles += 1
    }

    mutating func succeed(at now: TimeInterval) {
        lastSuccess = now
        failedCycles = 0
        nextCycleAt = 0
    }

    func ceilingReached(at now: TimeInterval) -> Bool {
        failedCycles > 0 && now - lastSuccess >= 600
    }
}
