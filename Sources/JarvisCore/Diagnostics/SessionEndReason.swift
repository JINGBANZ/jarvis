import Foundation

/// The reason a live coaching session ended. This closed set keeps *unclassified* text out of the
/// lifecycle while still making every terminal transition explicit: a provider-caused end carries
/// the failure that caused it, and Activity renders that failure's fixed sentence.
public enum SessionEndReason: Sendable, Equatable {
    case stoppedByUser
    case applicationQuit
    case replacedByNewSession
    /// Name kept even though the trigger is now provider-neutral: any missing transcription or
    /// brain credential, not only OpenAI's.
    case openAIAPIKeyMissing
    case permissionsMissing
    case brainRouteExhausted(last: ProviderFailure)
    case transcriptionStopped(reason: TranscriptionFailureReason)
    case audioCaptureUnavailable(failure: ProviderFailure)
    /// Jarvis-authored copy from the error catalog for a stop with no provider behind it.
    case unexpectedError(detail: String)

    var activityMessage: String {
        switch self {
        case .stoppedByUser:
            "session ended by user"
        case .applicationQuit:
            "session ended because Jarvis quit"
        case .replacedByNewSession:
            "session ended because a new session started"
        case .openAIAPIKeyMissing:
            "session ended by error — an API key is missing; check Settings → Connections"
        case .permissionsMissing:
            "session ended by error — a required permission is missing; check System Settings → Privacy & Security"
        case .brainRouteExhausted(let last):
            "session ended by error — all configured provider targets were exhausted; last target: \(last.activitySentence)"
        case .transcriptionStopped(let reason):
            "session ended by error — \(reason.activityDescription)"
        case .audioCaptureUnavailable(let failure):
            "session ended by error — \(failure.activitySentence)"
        case .unexpectedError(let detail):
            // Catalog copy is Jarvis-authored and already safe; redacting anyway keeps the rule
            // "nothing reaches a row unredacted" free of exceptions.
            "session ended by error — \(ProviderMessageRedaction.redact(detail))"
        }
    }
}
