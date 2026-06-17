import Testing
@testable import JarvisCore

@Suite struct SilenceBackoffTests {
    /// The first proactive silence check fires after the base interval.
    @Test func firstIntervalIsBase() {
        var b = SilenceBackoff(base: 30, maxInterval: 240)
        #expect(b.next() == 30)
    }

    /// While the user stays quiet, each successive check doubles the wait.
    @Test func doublesEachStepWhileQuiet() {
        var b = SilenceBackoff(base: 30, maxInterval: 240)
        #expect(b.next() == 30)
        #expect(b.next() == 60)
        #expect(b.next() == 120)
        #expect(b.next() == 240)
    }

    /// The interval never grows past the cap, no matter how long the silence lasts.
    @Test func capsAtMaxInterval() {
        var b = SilenceBackoff(base: 30, maxInterval: 240)
        for _ in 0..<4 { _ = b.next() }   // advance past the cap (30,60,120,240)
        #expect(b.next() == 240)
        #expect(b.next() == 240)
    }

    /// Hearing speech resets the backoff, so the next quiet gap starts from the base again.
    @Test func resetReturnsToBase() {
        var b = SilenceBackoff(base: 30, maxInterval: 240)
        _ = b.next(); _ = b.next()    // advance to 120
        b.reset()
        #expect(b.next() == 30)
    }
}
