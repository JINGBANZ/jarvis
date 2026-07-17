import Foundation

/// The catalog of the app's user-facing failures: the single source of truth for *which* failures are
/// loud (`.fatal` → alert + stop) versus quiet (`.degraded`). It owns the title + severity policy of each
/// named failure; dynamic copy composed at the failure site (e.g. a capture reason) is passed through.
/// Call sites reference these so the loudness policy is centralized and unit-testable.
public extension UserFacingError {
    /// No API key on Start. Realtime voice transcription always runs on the OpenAI key — whichever
    /// brain provider is selected — so the session never comes up: fatal.
    static var noAPIKey: UserFacingError {
        .init(title: "No OpenAI API key set",
              message: "Voice transcription needs an OpenAI API key even when the brain runs on a local CLI. Open \u{201C}Settings\u{2026}\u{201D} \u{2192} Brain, paste your key, then press Start.",
              severity: .fatal)
    }

    /// The selected brain provider's CLI isn't installed (or was removed since it was selected).
    /// The brain can't answer a single turn, so this is fatal on Start.
    static func brainCLIMissing(provider: String) -> UserFacingError {
        .init(title: "\(provider) not found",
              message: "The \(provider) command-line tool isn't installed on this Mac. Install and sign in to it, or switch the brain provider back to the OpenAI API in Settings \u{2192} Brain.",
              severity: .fatal)
    }

    /// The selected CLI is installed but definitively signed out (Codex: `auth.json` is its only
    /// credential store, so an absent marker is authoritative). Every brain turn would fail, so
    /// fail the Start instead of opening a pipeline that can never coach.
    static func brainCLINotSignedIn(provider: String) -> UserFacingError {
        .init(title: "\(provider) isn't signed in",
              message: "Sign in by running the \(provider) command once in Terminal, or switch the brain provider in Settings \u{2192} Brain, then press Start again.",
              severity: .fatal)
    }

    /// The selected CLI is installed but its sign-in couldn't be confirmed (Claude Code may keep
    /// credentials only in the macOS Keychain, which Jarvis deliberately doesn't probe). A false
    /// negative is possible, so this is a degraded notice, not a Start blocker — but it makes a
    /// never-working brain visible in the activity log instead of silent.
    static func brainCLISignInUnconfirmed(provider: String) -> UserFacingError {
        .init(title: "\(provider) sign-in unconfirmed",
              message: "Couldn't confirm \(provider) is signed in \u{2014} coaching turns may fail. If they do, run the CLI once in Terminal to sign in, then Stop and Start.",
              severity: .degraded)
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
