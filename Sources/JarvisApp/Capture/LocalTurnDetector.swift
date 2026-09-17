import Foundation
import JarvisCore

/// Never call `speechEvents` from a Core Audio IOProc: Silero's Core ML prediction allocates and
/// takes locks.
///
/// `@unchecked Sendable`: built on one thread, then called only from one serial delivery queue. It
/// is not safe for concurrent use.
final class LocalTurnDetector: @unchecked Sendable {
    private let resampler: Resampler
    private let voiceActivityDetector: SileroVoiceActivityDetector
    private var endpointDetector: SpeechEndpointDetector

    /// Nil when the model or converter is unavailable; callers must fail startup rather than run a
    /// client-commit session whose turns would never commit.
    init?(inputSampleRate: Double, trailingSilenceDuration: TimeInterval) {
        guard let voiceActivityDetector = SileroVoiceActivityDetector(),
              let resampler = Resampler(
                fromHz: inputSampleRate,
                toHz: Double(SileroVoiceActivityDetector.sampleRate)) else { return nil }
        self.voiceActivityDetector = voiceActivityDetector
        self.resampler = resampler
        endpointDetector = SpeechEndpointDetector(
            frameDuration: SileroVoiceActivityDetector.frameDuration,
            trailingSilenceDuration: trailingSilenceDuration)
    }

    /// `capturedAt` dates the first sample of `samples`.
    func speechEvents(
        from samples: [Int16],
        capturedAt: TimeInterval
    ) -> [SpeechEndpointDetector.Event] {
        voiceActivityDetector.classify(resampler.convert(samples)).compactMap { frame in
            endpointDetector.observe(
                speechProbability: frame.probability,
                frameStartedAt: capturedAt
                    + TimeInterval(frame.startOffsetSamples)
                        / TimeInterval(SileroVoiceActivityDetector.sampleRate))
        }
    }

    /// Deliberately leaves the endpoint policy alone: it holds an open turn the transcriber also
    /// tracks, and clearing it would strand that turn with no `.ended`.
    func resetStreamContinuity() {
        resampler.reset()
        voiceActivityDetector.reset()
    }
}
