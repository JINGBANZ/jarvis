import Foundation

/// Reports stable speech-activity edges from transient PCM16 observations without retaining audio.
///
/// The adaptive detector rejects the current noise floor. A short release delay bridges natural
/// pauses so provider adapters do not wake coaching in the middle of an utterance.
public struct PCM16SpeechActivityTracker {
    private let releaseDelay: TimeInterval
    private var detector = AdaptiveAudioActivityDetector(configuration: .init())
    private var lastActiveAt: TimeInterval?
    private var reportedActive = false

    public init(releaseDelay: TimeInterval = 0.5) {
        precondition(releaseDelay >= 0)
        self.releaseDelay = releaseDelay
    }

    /// Returns `true` for a new speech onset, `false` after the release delay, and `nil` when the
    /// externally visible state did not change.
    public mutating func observe(pcm16: Data, at timestamp: TimeInterval) -> Bool? {
        guard timestamp.isFinite else { return nil }
        let observation = detector.observe(pcm16: pcm16)
        guard observation.sampleCount > 0 else { return nil }

        if observation.isActive {
            lastActiveAt = timestamp
            guard !reportedActive else { return nil }
            reportedActive = true
            return true
        }

        guard reportedActive,
              let lastActiveAt,
              timestamp - lastActiveAt >= releaseDelay else {
            return nil
        }
        reportedActive = false
        self.lastActiveAt = nil
        return false
    }

    /// Clears the adaptive floor and activity state. Returns `false` when callers need to publish
    /// the end of a previously reported episode.
    public mutating func reset() -> Bool? {
        let change: Bool? = reportedActive ? false : nil
        detector = AdaptiveAudioActivityDetector(configuration: .init())
        lastActiveAt = nil
        reportedActive = false
        return change
    }
}
