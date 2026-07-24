import Testing
@testable import JarvisCore

@Suite struct RetryIncidentTests {
    private let schedule = RetrySchedule(
        maximumRetries: 2, initialDelay: 0.5, maximumDelay: 1)

    @Test func repeatedSignalsCannotResetAnActiveIncidentBudget() {
        var incident = RetryIncident(schedule: schedule)

        let began = incident.beginOrContinue()
        let first = incident.failed()
        let continuedOnce = incident.beginOrContinue()
        let second = incident.failed()
        let continuedTwice = incident.beginOrContinue()
        let exhausted = incident.failed()
        let beganAfterExhaustion = incident.beginOrContinue()
        let repeatedExhaustion = incident.failed()

        #expect(began)
        #expect(first == .retry(attempt: 1, maximum: 2, delay: 0.5))
        #expect(continuedOnce)
        #expect(second == .retry(attempt: 2, maximum: 2, delay: 1))
        #expect(continuedTwice)
        #expect(exhausted == .exhausted)
        #expect(!beganAfterExhaustion)
        #expect(repeatedExhaustion == .ignore)
    }

    @Test func successStartsALaterIncidentWithAFreshBudget() {
        var incident = RetryIncident(schedule: schedule)

        let began = incident.beginOrContinue()
        let first = incident.failed()
        incident.succeeded()
        let beganAgain = incident.beginOrContinue()
        let restarted = incident.failed()

        #expect(began)
        #expect(first == .retry(attempt: 1, maximum: 2, delay: 0.5))
        #expect(beganAgain)
        #expect(restarted == .retry(attempt: 1, maximum: 2, delay: 0.5))
    }

    @Test func stopSuppressesRetainedFailureCallbacksUntilReset() {
        var incident = RetryIncident(schedule: schedule)

        let began = incident.beginOrContinue()
        incident.stop()
        let beganAfterStop = incident.beginOrContinue()
        let stoppedFailure = incident.failed()

        incident.reset()
        let beganAfterReset = incident.beginOrContinue()

        #expect(began)
        #expect(!beganAfterStop)
        #expect(stoppedFailure == .ignore)
        #expect(beganAfterReset)
    }
}
