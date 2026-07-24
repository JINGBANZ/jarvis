import Testing
@testable import JarvisCore

@Suite struct RetryScheduleTests {
    @Test func returnsBoundedExponentialDelaysWithinBudget() {
        let schedule = RetrySchedule(
            maximumRetries: 6, initialDelay: 0.5, maximumDelay: 5)

        #expect((0...6).map { schedule.delay(forRetry: $0) }
            == [0.5, 1, 2, 4, 5, 5, nil])
    }

    @Test func rejectsNegativeAndExhaustedRetryIndices() {
        let schedule = RetrySchedule(
            maximumRetries: 2, initialDelay: 1, maximumDelay: 30)

        #expect(schedule.delay(forRetry: -1) == nil)
        #expect(schedule.delay(forRetry: 2) == nil)
    }
}
