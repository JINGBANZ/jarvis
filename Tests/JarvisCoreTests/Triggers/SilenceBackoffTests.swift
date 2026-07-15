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

    /// The idle cutoff gates the PROBE (the brain request), not the schedule: `shouldProbe` is
    /// evaluated against the quiet stretch at fire time, so a check that crosses the cutoff
    /// mid-wait stays quiet instead of billing one last request past the deadline.
    @Test func shouldProbeStopsAtTheIdleCutoff() {
        let b = SilenceBackoff(base: 30, maxInterval: 240, idleCutoff: 1800)
        #expect(b.shouldProbe(quietSoFar: 0))
        #expect(b.shouldProbe(quietSoFar: 1799))    // just under the cutoff: still probing
        #expect(!b.shouldProbe(quietSoFar: 1800))   // at the cutoff: suppressed
        #expect(!b.shouldProbe(quietSoFar: 9999))
    }

    /// The cutoff gates on the CURRENT quiet stretch: once speech (either side) restarts it,
    /// probing resumes — a shorter `quietSoFar` probes again without any state to clear.
    @Test func probingResumesOnceQuietStretchRestarts() {
        let b = SilenceBackoff(base: 30, maxInterval: 240, idleCutoff: 1800)
        #expect(!b.shouldProbe(quietSoFar: 2000))   // gone idle
        #expect(b.shouldProbe(quietSoFar: 10))      // speech restarted the stretch: probing again
    }

    /// Without an explicit cutoff, probing never stops (the default keeps old behavior).
    @Test func defaultHasNoIdleCutoff() {
        let b = SilenceBackoff(base: 30, maxInterval: 240)
        #expect(b.shouldProbe(quietSoFar: 1e9))
    }
}
