import Foundation

/// The sanitized reason a live coaching session ended. This closed set keeps raw provider, transport,
/// and device errors out of Activity while still making every terminal lifecycle transition explicit.
public enum SessionEndReason: Sendable, Equatable {
    case stoppedByUser
    case applicationQuit
    case replacedByNewSession
    case openAIAPIKeyMissing
    case brainProviderNotConfigured
    case permissionsMissing
    case brainRouteExhausted(lastProvider: BrainProvider)
    case transcriptionStopped(reason: TranscriptionFailureReason)
    case audioCaptureUnavailable
    case unexpectedError

    var activityMessage: String {
        switch self {
        case .stoppedByUser:
            "session ended by user"
        case .applicationQuit:
            "session ended because Jarvis quit"
        case .replacedByNewSession:
            "session ended because a new session started"
        case .openAIAPIKeyMissing:
            "session ended by error — the OpenAI API key is missing; check Settings → Connections"
        case .brainProviderNotConfigured:
            "session ended by error — no Primary brain provider is configured; check Settings → Brain"
        case .permissionsMissing:
            "session ended by error — a required permission is missing; check System Settings → Privacy & Security"
        case .brainRouteExhausted(let lastProvider):
            "session ended by error — all configured provider targets were exhausted; last target: \(lastProvider.displayName)"
        case .transcriptionStopped(let reason):
            "session ended by error — \(reason.activityDescription)"
        case .audioCaptureUnavailable:
            "session ended by error — audio capture became unavailable; check jarvis-debug.log"
        case .unexpectedError:
            "session ended by error — check jarvis-debug.log"
        }
    }
}
