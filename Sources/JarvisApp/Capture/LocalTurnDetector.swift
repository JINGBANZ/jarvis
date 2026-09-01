import Foundation
import JarvisCore

/// The whole local turn-detection pipeline for one audio stream: resample to the model's rate, score
/// each frame with Silero, and apply Core's endpoint policy.
///
/// One type so the two capture paths cannot drift apart. Turn detection has three pieces of stream
/// state (resampler filter history, Silero's LSTM state and carried context, and the endpoint
/// detector's own counters) that must be created together, fed in order, and reset together. Wiring
/// them separately at each call site is how one path ends up resampling at the wrong rate, or
/// resetting two of the three after a device change.
///
/// **Never call `speechEvents` from a Core Audio IOProc.** Silero runs a Core ML prediction, which
/// allocates and takes locks, so it belongs on the serial queue that delivers audio rather than the
/// realtime callback. Confine one instance per stream to that queue; it is not thread-safe.
///
/// `@unchecked Sendable` covers only that hand-off: a capture builds the detector on its own thread
/// and then passes the reference to its serial delivery queue, which is the sole caller from then on.
/// It is not a claim that the three pieces of stream state tolerate concurrent access, so never
/// call into an instance from a second queue.
final class LocalTurnDetector: @unchecked Sendable {
    private let resampler: Resampler
    private let voiceActivityDetector: SileroVoiceActivityDetector
    private var endpointDetector: SpeechEndpointDetector

    /// Returns nil if the model or the converter is unavailable, so a caller can fail startup rather
    /// than run a client-commit session whose turns would silently never commit.
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

    /// Score one delivered chunk and return whatever turn edges it completes.
    ///
    /// `capturedAt` dates the first sample of `samples`. A frame usually opens before this chunk,
    /// because one delivered chunk is shorter than a 32 ms frame, so each frame is dated from its own
    /// offset rather than from the chunk boundary.
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

    /// Drop stream continuity after the audio timeline breaks, such as a device rebuild: filter
    /// history and LSTM state both describe audio that no longer precedes what comes next.
    ///
    /// The endpoint policy is deliberately left alone. It holds an open turn that the transcriber
    /// downstream is also tracking, and clearing it here would strand that turn: no `.ended` would
    /// ever follow, so the speech buffer would stay open and the next utterance would merge into it.
    /// Its counters stay meaningful across the gap, so post-rebuild silence still closes the turn.
    func resetStreamContinuity() {
        resampler.reset()
        voiceActivityDetector.reset()
    }
}
