import Testing
@testable import JarvisCore

@Suite struct ReconnectBufferOverflowAccumulatorTests {
    @Test func reportsFirstOverflowAndLaterLossWithoutPerChunkNoise() {
        var accumulator = ReconnectBufferOverflowAccumulator(reportInterval: 5)

        #expect(accumulator.record([1], at: 0) == [1])
        #expect(accumulator.record([2], at: 1) == nil)
        #expect(accumulator.record([3], at: 2) == nil)
        #expect(accumulator.record([4], at: 6) == [2, 3, 4])
    }

    @Test func flushPreservesEvidenceAtStopAndResetStartsAFreshSession() {
        var accumulator = ReconnectBufferOverflowAccumulator(reportInterval: 5)
        #expect(accumulator.record([10], at: 0) == [10])
        #expect(accumulator.record([11, 12], at: 1) == nil)
        #expect(accumulator.flush(at: 2) == [11, 12])
        #expect(accumulator.flush(at: 3) == nil)

        accumulator.reset()
        #expect(accumulator.record([20], at: 3) == [20])
    }
}
