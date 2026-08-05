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
            "the OpenAI API quota is exhausted; check billing"
        case .authenticationFailed:
            "OpenAI rejected the API key; check Settings → Brain"
        case .accessDenied:
            "OpenAI denied transcription access; check your API project"
        case .configurationRejected:
            "OpenAI rejected the transcription configuration; check jarvis-debug.log"
        case .appleSpeechUnavailable:
            "Apple Speech transcription became unavailable; check jarvis-debug.log"
        }
    }
}
