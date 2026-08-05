import Testing
@testable import JarvisCore

@Suite struct SpeechEndpointDetectorTests {
    @Test func confirmsSpeechThenEndsAfterTrailingSilence() {
        var detector = SpeechEndpointDetector(
            frameDuration: 0.01,
            minimumSpeechDuration: 0.03,
            trailingSilenceDuration: 0.04)

        #expect(detector.observe(isSpeech: true, frameStartedAt: 1.00) == nil)
        #expect(detector.observe(isSpeech: true, frameStartedAt: 1.01) == nil)
        #expect(detector.observe(isSpeech: true, frameStartedAt: 1.02) == .started(at: 1.00))
        #expect(detector.observe(isSpeech: false, frameStartedAt: 1.03) == nil)
        #expect(detector.observe(isSpeech: false, frameStartedAt: 1.04) == nil)
        #expect(detector.observe(isSpeech: false, frameStartedAt: 1.05) == nil)
        let ended = detector.observe(isSpeech: false, frameStartedAt: 1.06)
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

        #expect(detector.observe(isSpeech: true, frameStartedAt: 0) == nil)
        #expect(detector.observe(isSpeech: true, frameStartedAt: 0.01) == nil)
        #expect(detector.observe(isSpeech: false, frameStartedAt: 0.02) == nil)
        #expect(detector.observe(isSpeech: false, frameStartedAt: 0.20) == nil)
    }

    @Test func bridgesAPauseShorterThanReleaseWindow() {
        var detector = SpeechEndpointDetector(
            frameDuration: 0.01,
            minimumSpeechDuration: 0.01,
            trailingSilenceDuration: 0.03)

        #expect(detector.observe(isSpeech: true, frameStartedAt: 0) == .started(at: 0))
        #expect(detector.observe(isSpeech: false, frameStartedAt: 0.01) == nil)
        #expect(detector.observe(isSpeech: false, frameStartedAt: 0.02) == nil)
        #expect(detector.observe(isSpeech: true, frameStartedAt: 0.03) == nil)
        #expect(detector.observe(isSpeech: false, frameStartedAt: 0.04) == nil)
        #expect(detector.observe(isSpeech: false, frameStartedAt: 0.05) == nil)
        let ended = detector.observe(isSpeech: false, frameStartedAt: 0.06)
        guard case .ended(let startedAt, let detectedAt) = ended else {
            Issue.record("expected a speech endpoint")
            return
        }
        #expect(startedAt == 0)
        #expect(abs(detectedAt - 0.07) < 0.000_001)
    }
}
