import Foundation

/// Separate onset and release thresholds (a Schmitt trigger, LiveKit's `activation - 0.15` for
/// Silero) keep speech near one threshold from chattering. There is deliberately no maximum speech
/// duration, as in upstream Silero: only silence ends a turn.
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

    /// Durations are in seconds. The 32 ms frame default is Silero's streaming chunk.
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

    public mutating func observe(
        speechProbability: Double,
        frameStartedAt: TimeInterval
    ) -> Event? {
        guard frameStartedAt.isFinite else { return nil }
        let probability = speechProbability.isFinite ? speechProbability : 0

        if let activeStartedAt {
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

    /// Private on purpose: clearing mid-turn would strand a turn the transcriber already opened.
    /// Drop continuity at the detector layer instead.
    private mutating func reset() {
        candidateStartedAt = nil
        candidateSpeechFrames = 0
        activeStartedAt = nil
        trailingSilenceFramesSeen = 0
    }
}
