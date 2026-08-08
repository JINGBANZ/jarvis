import Testing
@testable import JarvisCore

@Suite struct ReplayBufferEvictionAccumulatorTests {
    @Test func healthyWindowReportsOnceWithoutMaskingLaterRecoveryLoss() {
        var accumulator = ReplayBufferEvictionAccumulator(recoveryLossReportInterval: 5)

        #expect(accumulator.record([1], replayCoverageAtRisk: false, at: 0)
                == .boundedReplayWindowReached([1]))
        #expect(accumulator.record([2], replayCoverageAtRisk: false, at: 1) == nil)
        #expect(accumulator.record([3], replayCoverageAtRisk: true, at: 2)
                == .replayCoverageLost([3]))
        #expect(accumulator.record([4], replayCoverageAtRisk: true, at: 3) == nil)
        #expect(accumulator.record([5], replayCoverageAtRisk: true, at: 8)
                == .replayCoverageLost([4, 5]))
    }

    @Test func flushPreservesOnlyRecoveryLossAndResetStartsAFreshSession() {
        var accumulator = ReplayBufferEvictionAccumulator(recoveryLossReportInterval: 5)

        _ = accumulator.record([10], replayCoverageAtRisk: false, at: 0)
        #expect(accumulator.flush(at: 1) == nil)
        #expect(accumulator.record([11], replayCoverageAtRisk: true, at: 1)
                == .replayCoverageLost([11]))
        #expect(accumulator.record([12], replayCoverageAtRisk: true, at: 2) == nil)
        #expect(accumulator.flush(at: 3) == .replayCoverageLost([12]))

        accumulator.reset()
        #expect(accumulator.record([20], replayCoverageAtRisk: false, at: 3)
                == .boundedReplayWindowReached([20]))
        #expect(accumulator.record([21], replayCoverageAtRisk: true, at: 3)
                == .replayCoverageLost([21]))
    }
}
