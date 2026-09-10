import Testing
@testable import JarvisCore

@Suite struct BrainRouteSessionTests {
    @Test func lastTargetKeepsRetryingTemporaryFailuresUntilRecovery() {
        var route = BrainRouteSession(targetCount: 1)
        for count in 1...8 {
            #expect(route.recordFailure(.temporary) == .stay(failureCount: count))
        }
        route.recordSuccess()
        #expect(route.recordFailure(.temporary) == .stay(failureCount: 1))
        #expect(route.recordFailure(.permanent) == .exhausted(last: 0))
    }

    @Test func unavailableFallbackDoesNotDisplaceRecoverableTarget() {
        var route = BrainRouteSession(targetCount: 2)
        for count in 1...5 {
            #expect(route.recordFailure(.temporary, hasAvailableFallback: false) == .stay(failureCount: count))
        }
        #expect(route.activeIndex == 0)
    }

    @Test func thirdTemporaryFailureAdvances() {
        var route = BrainRouteSession(targetCount: 2)

        #expect(route.recordFailure(.temporary) == .stay(failureCount: 1))
        #expect(route.recordFailure(.temporary) == .stay(failureCount: 2))
        #expect(route.recordFailure(.temporary) == .advanced(from: 0, to: 1))
        #expect(route.activeIndex == 1)
        #expect(route.consecutiveFailures == 0)
    }

    @Test func successResetsCountWithoutMovingBackward() {
        var route = BrainRouteSession(targetCount: 2)
        _ = route.recordFailure(.temporary)
        _ = route.recordFailure(.temporary)

        route.recordSuccess()

        #expect(route.activeIndex == 0)
        #expect(route.consecutiveFailures == 0)
        #expect(route.recordFailure(.temporary) == .stay(failureCount: 1))
    }

    @Test func permanentFailureAdvancesImmediately() {
        var route = BrainRouteSession(targetCount: 2)

        #expect(route.recordFailure(.permanent) == .advanced(from: 0, to: 1))
        #expect(route.activeIndex == 1)
    }

    @Test func unavailableTargetSkipsWithoutFailureCount() {
        var route = BrainRouteSession(targetCount: 3)

        #expect(route.skipUnavailable() == .advanced(from: 0, to: 1))
        #expect(route.consecutiveFailures == 0)
        #expect(route.skipUnavailable() == .advanced(from: 1, to: 2))
    }

    @Test func routeMovesForwardUntilFinalExhaustion() {
        var route = BrainRouteSession(targetCount: 3)

        #expect(route.recordFailure(.permanent) == .advanced(from: 0, to: 1))
        #expect(route.recordFailure(.permanent) == .advanced(from: 1, to: 2))
        #expect(route.recordFailure(.permanent) == .exhausted(last: 2))
        #expect(route.activeIndex == 2)
    }
}
