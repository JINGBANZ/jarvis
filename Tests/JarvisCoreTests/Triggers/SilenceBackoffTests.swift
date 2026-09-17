import Testing
@testable import JarvisCore

@Suite struct SilenceBackoffTests {
    @Test func firstIntervalIsBase() {
        var b = SilenceBackoff(base: 30, maxInterval: 240)
        #expect(b.next() == 30)
    }

    @Test func quadruplesEachStepWhileQuiet() {
        var b = SilenceBackoff(base: 30, maxInterval: 1_000)
        #expect(b.next() == 30)
        #expect(b.next() == 120)
        #expect(b.next() == 480)
        #expect(b.next() == 1_000)
    }

    @Test func capsAtMaxInterval() {
        var b = SilenceBackoff(base: 30, maxInterval: 240)
        for _ in 0..<3 { _ = b.next() }
        #expect(b.next() == 240)
        #expect(b.next() == 240)
    }

    @Test func resetReturnsToBase() {
        var b = SilenceBackoff(base: 30, maxInterval: 240)
        _ = b.next(); _ = b.next()
        b.reset()
        #expect(b.next() == 30)
    }

    @Test func shouldProbeStopsAtTheIdleCutoff() {
        let b = SilenceBackoff(base: 30, maxInterval: 240, idleCutoff: 1800)
        #expect(b.shouldProbe(quietSoFar: 0))
        #expect(b.shouldProbe(quietSoFar: 1799))
        #expect(!b.shouldProbe(quietSoFar: 1800))
        #expect(!b.shouldProbe(quietSoFar: 9999))
    }

    @Test func probingResumesOnceQuietStretchRestarts() {
        let b = SilenceBackoff(base: 30, maxInterval: 240, idleCutoff: 1800)
        #expect(!b.shouldProbe(quietSoFar: 2000))
        #expect(b.shouldProbe(quietSoFar: 10))
    }

    @Test func defaultHasNoIdleCutoff() {
        let b = SilenceBackoff(base: 30, maxInterval: 240)
        #expect(b.shouldProbe(quietSoFar: 1e9))
    }
}
