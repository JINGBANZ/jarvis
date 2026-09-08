import Foundation

/// A fixed, non-sensitive explanation for a transcription failure that makes the running session
/// unusable. Raw provider messages remain in `jarvis-debug.log`; these cases are safe to persist in
/// the human-facing Activity log.
public enum TranscriptionFailureReason: CaseIterable, Sendable, Equatable {
    case connectionLost
    case quotaExceeded
    case authenticationFailed
    case accessDenied
    case configurationRejected
    case appleSpeechUnavailable

    public var activityDescription: String {
        switch self {
        case .connectionLost:
            "the transcription connection was lost; check jarvis-debug.log"
        case .quotaExceeded:
            "the transcription API quota is exhausted; check billing"
        case .authenticationFailed:
            "the transcription provider rejected the API key; check Settings → Connections"
        case .accessDenied:
            "the transcription provider denied access; check your API project"
        case .configurationRejected:
            "the transcription provider rejected the configuration; check jarvis-debug.log"
        case .appleSpeechUnavailable:
            "Apple Speech transcription became unavailable; check jarvis-debug.log"
        }
    }

    /// Whether this reason describes an account/credential/configuration problem with the provider
    /// itself — one that equally threatens every stream open to that provider — rather than something
    /// local to the one stream that reported it.
    ///
    /// `AppDelegate` uses this to decide whether a "them" (system-audio) terminal failure must
    /// escalate the whole session instead of silently degrading to mic-only. A bad API key or an
    /// exhausted quota closes BOTH the mic and system-audio sockets for the same reason, often from
    /// two delegate queues near-simultaneously; degrading on whichever side happens to report first
    /// would hide the real cause behind a misleading system-audio-specific degradation notice moments
    /// before the mic side fails from the identical cause. `.connectionLost` stays non-escalating on
    /// purpose: a dropped system-audio socket is a transport blip specific to that one stream, not
    /// evidence the provider account itself is broken, so degrading to mic-only remains the right
    /// response. `.appleSpeechUnavailable` is definitionally local — Apple Speech has no shared
    /// account/quota surface across streams.
    ///
    /// `CaseIterable` conformance backs a unit test that enumerates every case here, so a future
    /// reason forces a deliberate escalate-or-degrade decision instead of silently defaulting.
    public var affectsEveryStream: Bool {
        switch self {
        case .authenticationFailed, .quotaExceeded, .accessDenied, .configurationRejected:
            true
        case .connectionLost, .appleSpeechUnavailable:
            false
        }
    }
}
