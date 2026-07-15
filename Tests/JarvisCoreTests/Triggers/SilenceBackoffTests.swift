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

    /// Once the quiet stretch reaches the idle cutoff, probing stops (nil): the user has stepped
    /// away, and each probe into the empty room still bills a full brain request.
    @Test func idleCutoffStopsProbing() {
        var b = SilenceBackoff(base: 30, maxInterval: 240, idleCutoff: 1800)
        #expect(b.next(quietSoFar: 0) == 30)
        #expect(b.next(quietSoFar: 1799) != nil)   // just under the cutoff: still probing
        #expect(b.next(quietSoFar: 1800) == nil)   // at the cutoff: stop
        #expect(b.next(quietSoFar: 9999) == nil)
    }

    /// The cutoff gates on the CURRENT quiet stretch, so speech (which resets the stretch) re-arms
    /// probing — the next gap is measured afresh from zero.
    @Test func probingResumesOnceQuietStretchRestarts() {
        var b = SilenceBackoff(base: 30, maxInterval: 240, idleCutoff: 1800)
        _ = b.next(quietSoFar: 0); _ = b.next(quietSoFar: 30)   // advance to 120
        #expect(b.next(quietSoFar: 2000) == nil)                // gone idle
        b.reset()                                               // speech heard
        #expect(b.next(quietSoFar: 10) == 30)                   // probing again, from the base
    }

    /// Without an explicit cutoff, probing never stops (the default keeps old behavior).
    @Test func defaultHasNoIdleCutoff() {
        var b = SilenceBackoff(base: 30, maxInterval: 240)
        #expect(b.next(quietSoFar: 1e9) == 30)
    }
}
