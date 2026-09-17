import Foundation

/// The release delay bridges natural pauses so coaching doesn't wake mid-utterance.
public struct PCM16SpeechActivityTracker {
    private let releaseDelay: TimeInterval
    private var detector = AdaptiveAudioActivityDetector(configuration: .init())
    private var lastActiveAt: TimeInterval?
    private var reportedActive = false

    public init(releaseDelay: TimeInterval = 0.5) {
        precondition(releaseDelay >= 0)
        self.releaseDelay = releaseDelay
    }

    /// True on a new onset, false once the release delay passes, nil when unchanged.
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

    /// False when a reported episode was still active and its end must be published.
    public mutating func reset() -> Bool? {
        let change: Bool? = reportedActive ? false : nil
        detector = AdaptiveAudioActivityDetector(configuration: .init())
        lastActiveAt = nil
        reportedActive = false
        return change
    }
}
