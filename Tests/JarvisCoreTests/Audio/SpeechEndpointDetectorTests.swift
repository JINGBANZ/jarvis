import Testing
@testable import JarvisCore

@Suite struct SpeechEndpointDetectorTests {
    /// Silero's streaming cadence, so the production-shaped cases below run on production numbers.
    private static let frame = 0.032

    /// Feed a run of frames at one probability, collecting whatever edges come out.
    private func feed(
        _ detector: inout SpeechEndpointDetector,
        probability: Double,
        seconds: Double,
        from start: Double,
        into events: inout [SpeechEndpointDetector.Event]
    ) -> Double {
        var at = start
        let frames = Int((seconds / Self.frame).rounded())
        for _ in 0..<frames {
            if let event = detector.observe(speechProbability: probability, frameStartedAt: at) {
                events.append(event)
            }
            at += Self.frame
        }
        return at
    }

    @Test func confirmsSpeechThenEndsAfterTrailingSilence() {
        var detector = SpeechEndpointDetector(
            frameDuration: 0.01,
            minimumSpeechDuration: 0.03,
            trailingSilenceDuration: 0.04)

        #expect(detector.observe(speechProbability: 0.9, frameStartedAt: 1.00) == nil)
        #expect(detector.observe(speechProbability: 0.9, frameStartedAt: 1.01) == nil)
        #expect(detector.observe(speechProbability: 0.9, frameStartedAt: 1.02) == .started(at: 1.00))
        #expect(detector.observe(speechProbability: 0.0, frameStartedAt: 1.03) == nil)
        #expect(detector.observe(speechProbability: 0.0, frameStartedAt: 1.04) == nil)
        #expect(detector.observe(speechProbability: 0.0, frameStartedAt: 1.05) == nil)
        let ended = detector.observe(speechProbability: 0.0, frameStartedAt: 1.06)
        guard case .ended(let startedAt, let detectedAt) = ended else {
            Issue.record("expected a speech endpoint")
            return
        }
        #expect(startedAt == 1.00)
        #expect(abs(detectedAt - 1.07) < 0.000_001)
    }

    @Test func rejectsShortSpeechBlip() {
        var detector = SpeechEndpointDetector(
            frameDuration: 0.01,
            minimumSpeechDuration: 0.03,
            trailingSilenceDuration: 0.04)

        #expect(detector.observe(speechProbability: 0.9, frameStartedAt: 0) == nil)
        #expect(detector.observe(speechProbability: 0.9, frameStartedAt: 0.01) == nil)
        #expect(detector.observe(speechProbability: 0.0, frameStartedAt: 0.02) == nil)
        #expect(detector.observe(speechProbability: 0.0, frameStartedAt: 0.20) == nil)
    }

    @Test func bridgesAPauseShorterThanReleaseWindow() {
        var detector = SpeechEndpointDetector(
            frameDuration: 0.01,
            minimumSpeechDuration: 0.01,
            trailingSilenceDuration: 0.03)

        #expect(detector.observe(speechProbability: 0.9, frameStartedAt: 0) == .started(at: 0))
        #expect(detector.observe(speechProbability: 0.0, frameStartedAt: 0.01) == nil)
        #expect(detector.observe(speechProbability: 0.0, frameStartedAt: 0.02) == nil)
        #expect(detector.observe(speechProbability: 0.9, frameStartedAt: 0.03) == nil)
        #expect(detector.observe(speechProbability: 0.0, frameStartedAt: 0.04) == nil)
        #expect(detector.observe(speechProbability: 0.0, frameStartedAt: 0.05) == nil)
        let ended = detector.observe(speechProbability: 0.0, frameStartedAt: 0.06)
        guard case .ended(let startedAt, let detectedAt) = ended else {
            Issue.record("expected a speech endpoint")
            return
        }
        #expect(startedAt == 0)
        #expect(abs(detectedAt - 0.07) < 0.000_001)
    }

    /// Between the two thresholds the turn must neither close nor restart: that gap is the whole
    /// point of the Schmitt trigger, and a single threshold would chatter here.
    @Test func holdsTurnOpenBetweenActivationAndReleaseThresholds() {
        var detector = SpeechEndpointDetector(
            frameDuration: 0.01,
            minimumSpeechDuration: 0.01,
            trailingSilenceDuration: 0.03,
            activationThreshold: 0.5,
            releaseThreshold: 0.35)

        #expect(detector.observe(speechProbability: 0.9, frameStartedAt: 0) == .started(at: 0))
        // 0.4 is below activation but above release: still speech, so silence never accrues.
        for step in 1...20 {
            #expect(detector.observe(
                speechProbability: 0.4, frameStartedAt: Double(step) / 100) == nil)
        }
        // Dropping under release finally starts the countdown.
        #expect(detector.observe(speechProbability: 0.2, frameStartedAt: 0.21) == nil)
        #expect(detector.observe(speechProbability: 0.2, frameStartedAt: 0.22) == nil)
        guard case .ended = detector.observe(speechProbability: 0.2, frameStartedAt: 0.23) else {
            Issue.record("expected the turn to close once probability fell below release")
            return
        }
    }

    /// Keyboard typing measured at p <= 0.023 against a 0.5 activation threshold. No turn may open,
    /// however long it runs: this is the production failure that concatenated four utterances.
    @Test func neverOpensATurnOnTypingProbabilities() {
        var detector = SpeechEndpointDetector(
            frameDuration: Self.frame, trailingSilenceDuration: 0.8)
        var events: [SpeechEndpointDetector.Event] = []
        _ = feed(&detector, probability: 0.023, seconds: 120, from: 0, into: &events)
        #expect(events.isEmpty)
    }

    /// The production pattern from session 2026-08-30_19-40-42_4195: five utterances separated by
    /// 8-18 s of typing. The old detector produced one 86 s turn; each utterance must now stand alone.
    @Test func splitsTheProductionFailurePatternIntoFiveTurns() {
        var detector = SpeechEndpointDetector(
            frameDuration: Self.frame, trailingSilenceDuration: 0.8)
        var events: [SpeechEndpointDetector.Event] = []
        var at = 0.0

        at = feed(&detector, probability: 0.02, seconds: 2, from: at, into: &events)
        for gap in [18.0, 14.0, 8.8, 10.3] {
            at = feed(&detector, probability: 0.9, seconds: 3, from: at, into: &events)
            at = feed(&detector, probability: 0.02, seconds: gap, from: at, into: &events)
        }
        at = feed(&detector, probability: 0.9, seconds: 3, from: at, into: &events)
        _ = feed(&detector, probability: 0.02, seconds: 5, from: at, into: &events)

        let started = events.filter { if case .started = $0 { return true } else { return false } }
        let ended = events.filter { if case .ended = $0 { return true } else { return false } }
        #expect(started.count == 5)
        #expect(ended.count == 5)

        // Every turn must close promptly after its speech, not absorb the following silence.
        for event in ended {
            guard case .ended(let startedAt, let detectedAt) = event else { continue }
            let length = detectedAt - startedAt
            #expect(length > 3.0)
            #expect(length < 3.0 + 0.8 + 0.5)
        }
    }

    /// Silence bounds a turn; speech length never does. A long explanation must stay one turn rather
    /// than being chopped by a duration cap.
    @Test func doesNotCapLongSpeech() {
        var detector = SpeechEndpointDetector(
            frameDuration: Self.frame, trailingSilenceDuration: 0.8)
        var events: [SpeechEndpointDetector.Event] = []
        var at = feed(&detector, probability: 0.9, seconds: 180, from: 0, into: &events)
        #expect(events.count == 1)
        #expect(events.first.map { if case .started = $0 { true } else { false } } == true)

        at = feed(&detector, probability: 0.0, seconds: 1, from: at, into: &events)
        _ = at
        #expect(events.count == 2)
        guard case .ended(let startedAt, let detectedAt) = events[1] else {
            Issue.record("expected the long turn to close on silence")
            return
        }
        #expect(startedAt == 0)
        #expect(detectedAt > 180)
    }

    /// A detector that starts failing must still close an open turn. If failed frames stopped
    /// reaching the policy, `localSpeechActive` would stay set and every automatic coaching attempt
    /// would park on a turn that can never settle. Scoring failures as silence keeps that bounded.
    @Test func closesAnOpenTurnWhenScoringDegradesToSilence() {
        var detector = SpeechEndpointDetector(
            frameDuration: Self.frame, trailingSilenceDuration: 0.8)
        var events: [SpeechEndpointDetector.Event] = []
        var at = feed(&detector, probability: 0.9, seconds: 2, from: 0, into: &events)
        #expect(events.count == 1)

        // Every later frame scores 0, the value a failed prediction contributes.
        at = feed(&detector, probability: 0, seconds: 5, from: at, into: &events)
        _ = at
        #expect(events.count == 2)
        guard case .ended = events[1] else {
            Issue.record("expected the open turn to close once scoring degraded")
            return
        }
    }

    /// A model that returns NaN must read as silence rather than latch a turn open forever.
    @Test func treatsNonFiniteProbabilityAsSilence() {
        var detector = SpeechEndpointDetector(
            frameDuration: 0.01,
            minimumSpeechDuration: 0.01,
            trailingSilenceDuration: 0.02)

        #expect(detector.observe(speechProbability: 0.9, frameStartedAt: 0) == .started(at: 0))
        #expect(detector.observe(speechProbability: .nan, frameStartedAt: 0.01) == nil)
        guard case .ended = detector.observe(speechProbability: .nan, frameStartedAt: 0.02) else {
            Issue.record("expected NaN to be treated as silence")
            return
        }
    }
}
