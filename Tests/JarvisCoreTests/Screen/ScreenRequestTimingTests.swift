import Testing
@testable import JarvisCore

@Suite struct ScreenRequestTimingTests {
    @Test func firstStableChangeWaitsOnlyForPiggyback() {
        #expect(ScreenRequestTiming.fallbackDeadline(
            candidateAt: 100,
            lastVisualRequestAt: nil,
            piggybackWait: 2,
            minimumRequestInterval: 60
        ) == 102)
    }

    @Test func repeatedChangesCannotCreateMoreThanOneScreenOnlyRequestPerInterval() {
        #expect(ScreenRequestTiming.fallbackDeadline(
            candidateAt: 110,
            lastVisualRequestAt: 100,
            piggybackWait: 2,
            minimumRequestInterval: 60
        ) == 160)
    }

    @Test func lateChangeStillGetsItsPiggybackWindow() {
        #expect(ScreenRequestTiming.fallbackDeadline(
            candidateAt: 170,
            lastVisualRequestAt: 100,
            piggybackWait: 2,
            minimumRequestInterval: 60
        ) == 172)
    }
}
