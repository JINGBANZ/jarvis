import Testing
@testable import JarvisCore

@Suite struct ClockTests {
    @Test func manualClockAdvances() {
        let clock = ManualClock(now: 100)
        #expect(clock.now() == 100)
        clock.advance(by: 5)
        #expect(clock.now() == 105)
    }
}
