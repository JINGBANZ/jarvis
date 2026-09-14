import Testing
@testable import JarvisCore

@Suite struct BrainCycleRecoveryTests {
    private func failure(_ message: String) -> ProviderFailure {
        ProviderFailure(source: .brain(.openAI), stage: .request, category: .unknown,
            disposition: .temporary, identity: .init(), message: message)
    }

    @Test func cooldownCapsAndSuccessResetsWithoutForgettingPermanentTargets() {
        var health = BrainCycleRecovery()
        let target = BrainTarget(provider: .openAI, modelID: "test")
        health.markPermanent(target, failure: ProviderFailure(source: .brain(.openAI), stage: .request,
            category: .unknown, disposition: .permanent, identity: .init(), message: "invalid key"))
        for delay in [0.0, 5, 15, 45, 120, 120] {
            health.fail(at: 20, failure: failure("timed out"))
            #expect(health.nextCycleAt == 20 + delay)
        }
        #expect(health.streak?.cycles == 6)
        health.succeed()
        #expect(health.streak == nil)
        #expect(health.permanentFailures[target] != nil)
        health.fail(at: 40, failure: failure("timed out"))
        #expect(health.nextCycleAt == 40)
    }

    /// Quiet time before a failure is not an outage, so the ceiling runs from the streak's first
    /// failed cycle, and the session end reports the streak's latest cause.
    @Test func ceilingRunsFromTheStreaksFirstFailureAndKeepsTheLatestCause() {
        var health = BrainCycleRecovery()
        #expect(!health.ceilingReached(at: 10_000))
        health.fail(at: 1_440, failure: failure("first outage"))
        #expect(!health.ceilingReached(at: 1_440))
        health.fail(at: 1_700, failure: failure("latest outage"))
        #expect(health.remainingBeforeCeiling(at: 1_700) == 340)
        #expect(!health.ceilingReached(at: 2_039))
        #expect(health.ceilingReached(at: 2_040))
        #expect(health.streak?.lastFailure.message == "latest outage")
        health.succeed()
        #expect(!health.ceilingReached(at: 5_000))
        health.fail(at: 5_000, failure: failure("new outage"))
        #expect(!health.ceilingReached(at: 5_599))
        #expect(health.ceilingReached(at: 5_600))
    }
}
