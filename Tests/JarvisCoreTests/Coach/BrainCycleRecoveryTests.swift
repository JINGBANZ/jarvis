import Testing
@testable import JarvisCore

@Suite struct BrainCycleRecoveryTests {
    @Test func cooldownCapsAndSuccessResetsWithoutForgettingPermanentTargets() {
        var health = BrainCycleRecovery(startedAt: 10)
        let target = BrainTarget(provider: .openAI, modelID: "test")
        health.markPermanent(target, failure: ProviderFailure(source: .brain(.openAI), stage: .request,
            category: .unknown, disposition: .permanent, identity: .init(), message: "invalid key"))
        for delay in [0.0, 5, 15, 45, 120, 120] {
            health.fail(at: 20)
            #expect(health.nextCycleAt == 20 + delay)
        }
        health.succeed(at: 30)
        #expect(health.failedCycles == 0)
        #expect(health.lastSuccess == 30)
        #expect(health.permanentFailures[target] != nil)
        health.fail(at: 40)
        #expect(health.nextCycleAt == 40)
    }

    @Test func ceilingRequiresFailureAndMeasuresFromLastSuccess() {
        var health = BrainCycleRecovery(startedAt: 10)
        #expect(!health.ceilingReached(at: 999))
        health.fail(at: 600)
        #expect(!health.ceilingReached(at: 609))
        #expect(health.ceilingReached(at: 610))
        health.succeed(at: 650)
        #expect(!health.ceilingReached(at: 1500))
        health.fail(at: 1200)
        #expect(!health.ceilingReached(at: 1249))
        #expect(health.ceilingReached(at: 1250))
    }
}
