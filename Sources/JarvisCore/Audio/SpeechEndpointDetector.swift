import Foundation

/// Turns frame-level voice decisions into stable speech edges without retaining audio.
///
/// A short run of positive frames confirms onset so isolated clicks never create an OpenAI turn.
/// Once active, a configurable trailing-silence window bridges normal mid-sentence pauses and emits
/// one endpoint suitable for an explicit Realtime audio-buffer commit.
public struct SpeechEndpointDetector: Sendable {
    public enum Event: Equatable, Sendable {
        case started(at: TimeInterval)
        case ended(startedAt: TimeInterval, detectedAt: TimeInterval)
    }

    private let frameDuration: TimeInterval
    private let minimumSpeechFrames: Int
    private let trailingSilenceFrames: Int

    private var candidateStartedAt: TimeInterval?
    private var candidateSpeechFrames = 0
    private var activeStartedAt: TimeInterval?
    private var trailingSilenceFramesSeen = 0

    public init(
        frameDuration: TimeInterval = 0.01,
        minimumSpeechDuration: TimeInterval = 0.1,
        trailingSilenceDuration: TimeInterval
    ) {
        precondition(frameDuration > 0 && frameDuration.isFinite)
        precondition(minimumSpeechDuration >= 0 && minimumSpeechDuration.isFinite)
        precondition(trailingSilenceDuration >= 0 && trailingSilenceDuration.isFinite)
        self.frameDuration = frameDuration
        minimumSpeechFrames = max(1, Int(ceil(minimumSpeechDuration / frameDuration)))
        trailingSilenceFrames = max(1, Int(ceil(trailingSilenceDuration / frameDuration)))
    }

    /// Observe one frame. Timestamps identify the frame's start on the shared capture timeline.
    public mutating func observe(isSpeech: Bool, frameStartedAt: TimeInterval) -> Event? {
        guard frameStartedAt.isFinite else { return nil }

        if let activeStartedAt {
            if isSpeech {
                trailingSilenceFramesSeen = 0
                return nil
            }
            trailingSilenceFramesSeen += 1
            guard trailingSilenceFramesSeen >= trailingSilenceFrames else { return nil }
            let detectedAt = frameStartedAt + frameDuration
            reset()
            return .ended(startedAt: activeStartedAt, detectedAt: detectedAt)
        }

        guard isSpeech else {
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

    public mutating func reset() {
        candidateStartedAt = nil
        candidateSpeechFrames = 0
        activeStartedAt = nil
        trailingSilenceFramesSeen = 0
    }
}
