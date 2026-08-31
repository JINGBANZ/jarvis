import Foundation

/// Turns per-frame speech *probabilities* into stable speech edges without retaining audio.
///
/// A short run of confident frames confirms onset so an isolated transient never creates an OpenAI
/// turn. Once active, a configurable trailing-silence window bridges normal mid-sentence pauses and
/// emits one endpoint suitable for an explicit Realtime audio-buffer commit.
///
/// Onset and release use **separate thresholds** (a Schmitt trigger): audio must clear
/// `activationThreshold` to open a turn, but only has to stay above the lower `releaseThreshold` to
/// keep it open. A single threshold makes speech hovering near it chatter between states; the gap
/// gives the active state deliberate inertia. This mirrors Silero's own convention as adopted by
/// LiveKit (`deactivation = activation - 0.15`).
///
/// There is deliberately **no maximum speech duration**: a turn is bounded by *silence*, never by how
/// long someone talks, so a long explanation is never cut mid-sentence. Upstream Silero makes the same
/// choice: its `max_speech_duration_s` defaults to infinity.
public struct SpeechEndpointDetector: Sendable {
    public enum Event: Equatable, Sendable {
        case started(at: TimeInterval)
        case ended(startedAt: TimeInterval, detectedAt: TimeInterval)
    }

    private let frameDuration: TimeInterval
    private let minimumSpeechFrames: Int
    private let trailingSilenceFrames: Int
    private let activationThreshold: Double
    private let releaseThreshold: Double

    private var candidateStartedAt: TimeInterval?
    private var candidateSpeechFrames = 0
    private var activeStartedAt: TimeInterval?
    private var trailingSilenceFramesSeen = 0

    /// - Parameters:
    ///   - frameDuration: seconds of audio per observed frame (Silero streams 32 ms chunks).
    ///   - minimumSpeechDuration: confident audio required before a turn opens.
    ///   - trailingSilenceDuration: quiet required to close a turn.
    ///   - activationThreshold: probability at or above which idle audio becomes candidate speech.
    ///   - releaseThreshold: probability below which active speech starts accruing silence. Must not
    ///     exceed `activationThreshold`, or the state machine would oscillate instead of latching.
    public init(
        frameDuration: TimeInterval = 0.032,
        minimumSpeechDuration: TimeInterval = 0.1,
        trailingSilenceDuration: TimeInterval,
        activationThreshold: Double = 0.5,
        releaseThreshold: Double = 0.35
    ) {
        precondition(frameDuration > 0 && frameDuration.isFinite)
        precondition(minimumSpeechDuration >= 0 && minimumSpeechDuration.isFinite)
        precondition(trailingSilenceDuration >= 0 && trailingSilenceDuration.isFinite)
        precondition(activationThreshold.isFinite && releaseThreshold.isFinite)
        precondition(releaseThreshold <= activationThreshold)
        self.frameDuration = frameDuration
        self.activationThreshold = activationThreshold
        self.releaseThreshold = releaseThreshold
        minimumSpeechFrames = max(1, Int(ceil(minimumSpeechDuration / frameDuration)))
        trailingSilenceFrames = max(1, Int(ceil(trailingSilenceDuration / frameDuration)))
    }

    /// Observe one frame. Timestamps identify the frame's start on the shared capture timeline.
    /// A non-finite probability is treated as silence rather than trusted.
    public mutating func observe(
        speechProbability: Double,
        frameStartedAt: TimeInterval
    ) -> Event? {
        guard frameStartedAt.isFinite else { return nil }
        let probability = speechProbability.isFinite ? speechProbability : 0

        if let activeStartedAt {
            // Hysteresis: hold the turn open while the model still leans "speech".
            if probability >= releaseThreshold {
                trailingSilenceFramesSeen = 0
                return nil
            }
            trailingSilenceFramesSeen += 1
            guard trailingSilenceFramesSeen >= trailingSilenceFrames else { return nil }
            let detectedAt = frameStartedAt + frameDuration
            reset()
            return .ended(startedAt: activeStartedAt, detectedAt: detectedAt)
        }

        guard probability >= activationThreshold else {
            candidateStartedAt = nil
            candidateSpeechFrames = 0
            return nil
        }
        if candidateStartedAt == nil { candidateStartedAt = frameStartedAt }
        candidateSpeechFrames += 1
        guard candidateSpeechFrames >= minimumSpeechFrames,
              let startedAt = candidateStartedAt else { return nil }
        activeStartedAt = startedAt
        candidateStartedAt = nil
        candidateSpeechFrames = 0
        trailingSilenceFramesSeen = 0
        return .started(at: startedAt)
    }

    /// Internal only. Callers that need to drop stream continuity after an audio-timeline break do
    /// so at the detector layer; clearing the endpoint policy would strand a turn the transcriber
    /// downstream has already opened.
    private mutating func reset() {
        candidateStartedAt = nil
        candidateSpeechFrames = 0
        activeStartedAt = nil
        trailingSilenceFramesSeen = 0
    }
}
