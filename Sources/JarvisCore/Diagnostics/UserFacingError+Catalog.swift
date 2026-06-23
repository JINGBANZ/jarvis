import Foundation

/// The catalog of the app's user-facing failures: the single source of truth for *which* failures are
/// loud (`.fatal` → alert + stop) versus quiet (`.degraded`/`.info`). Call sites reference these instead
/// of inlining titles, copy, and severities, so the loudness policy is centralized and unit-testable.
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

    /// The mic ("me") transcription socket gave up (bad key / quota / network). Coaching can't continue.
    static var microphoneDisconnected: UserFacingError {
        .init(title: "Microphone disconnected",
              message: "Jarvis lost the microphone connection (often a bad API key, quota, or network issue). Coaching has stopped.",
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
