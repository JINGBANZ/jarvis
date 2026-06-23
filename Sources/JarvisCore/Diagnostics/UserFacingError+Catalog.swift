import Foundation

/// The catalog of the app's user-facing failures: the single source of truth for *which* failures are
/// loud (`.fatal` → alert + stop) versus quiet (`.degraded`). It owns the title + severity policy of each
/// named failure; dynamic copy composed at the failure site (e.g. a capture reason) is passed through.
/// Call sites reference these so the loudness policy is centralized and unit-testable.
public extension UserFacingError {
    /// No API key on Start. The session never comes up, so this is fatal.
    static var noAPIKey: UserFacingError {
        .init(title: "No OpenAI API key set",
              message: "Open \u{201C}Settings\u{2026}\u{201D} from the Jarvis menu, paste your key, then press Start.",
              severity: .fatal)
    }

    /// Audio capture couldn't be built or started. `reason` is the human-readable cause from the capture
    /// layer (no input device, permission, unreadable rate, …). Fatal — there's nothing to coach from.
    static func captureFailed(reason: String) -> UserFacingError {
        .init(title: "Couldn't start audio capture", message: reason, severity: .fatal)
    }

    /// The mic ("me") transcription socket gave up (bad key / quota / network) — NOT a mic-hardware
    /// failure (that's `captureFailed`). Coaching can't continue, so it's fatal.
    static var transcriptionStopped: UserFacingError {
        .init(title: "Transcription stopped",
              message: "Jarvis lost its connection to the transcription service (often a bad API key, quota, or network issue). Coaching has stopped.",
              severity: .fatal)
    }

    /// The system-audio ("them") socket gave up. The mic still works, so this is a graceful degrade —
    /// a non-blocking notice, NOT a session-ending alert.
    static var systemAudioStopped: UserFacingError {
        .init(title: "System audio stopped",
              message: "Stopped transcribing the other side's audio; your microphone is still active.",
              severity: .degraded)
    }
}
