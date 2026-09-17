import Foundation

/// A closed set, so unclassified text never enters the lifecycle.
public enum SessionEndReason: Sendable, Equatable {
    case stoppedByUser
    case applicationQuit
    case replacedByNewSession
    /// Any provider's missing transcription or brain credential.
    case apiKeyMissing
    case permissionsMissing
    case brainRouteExhausted(last: ProviderFailure)
    case brainRecoveryExpired(last: ProviderFailure)
    case transcriptionStopped(failure: ProviderFailure)
    case audioCaptureUnavailable(failure: ProviderFailure)
    /// Jarvis-authored catalog copy only, never provider text.
    case unexpectedError(detail: String)

    var activityMessage: String {
        switch self {
        case .stoppedByUser:
            "session ended by user"
        case .applicationQuit:
            "session ended because Jarvis quit"
        case .replacedByNewSession:
            "session ended because a new session started"
        case .apiKeyMissing:
            "session ended by error — an API key is missing; check Settings → Connections"
        case .permissionsMissing:
            "session ended by error — a required permission is missing; check System Settings → Privacy & Security"
        case .brainRouteExhausted(let last):
            "session ended by error — all configured provider targets were exhausted; last target: \(last.activitySentence)"
        case .brainRecoveryExpired(let last):
            "session ended by error — coaching kept failing for \(Int(BrainCycleRecovery.ceiling / 60)) minutes; last error: \(last.activitySentence)"
        case .transcriptionStopped(let failure):
            "session ended by error — \(failure.activitySentence)"
        case .audioCaptureUnavailable(let failure):
            "session ended by error — \(failure.activitySentence)"
        case .unexpectedError(let detail):
            // Already safe, but redacted anyway so nothing reaches a row unredacted, no exceptions.
            "session ended by error — \(ProviderMessageRedaction.redact(detail))"
        }
    }
}
