import Testing
@testable import JarvisCore

@Suite struct GuardrailsTests {
    private func makeGuardrails(_ clock: ManualClock) -> Guardrails {
        Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
    }

    @Test func cooldownSuppressesSecondResponse() {
        let clock = ManualClock(now: 0)
        let g = makeGuardrails(clock)
        #expect(g.allow())
        g.noteSpoke()
        clock.advance(by: 5)            // still inside 12s cooldown
        #expect(!g.allow())
        clock.advance(by: 8)            // now 13s > cooldown
        #expect(g.allow())
    }

    @Test func rateCapBlocksFifthInOneMinute() {
        let clock = ManualClock(now: 0)
        let g = makeGuardrails(clock)
        for _ in 0..<4 {
            #expect(g.allow())
            g.noteSpoke()
            clock.advance(by: 13)       // clear cooldown each time; 4 spokes over ~52s
        }
        #expect(!g.allow())             // 5th within the same rolling minute is blocked
    }

    @Test func rateCapWindowSlides() {
        let clock = ManualClock(now: 0)
        let g = makeGuardrails(clock)
        for _ in 0..<4 { #expect(g.allow()); g.noteSpoke(); clock.advance(by: 13) }
        clock.advance(by: 60)           // old interjections fall out of the 60s window
        #expect(g.allow())
    }

    @Test func muteSuppressesEverything() {
        let clock = ManualClock(now: 0)
        let g = makeGuardrails(clock)
        g.setMuted(true)
        #expect(!g.allow())
        g.setMuted(false)
        #expect(g.allow())
    }
}
