import Foundation

/// The catalog of the app's user-facing failures: the single source of truth for each failure's
/// lifecycle consequence. Presentation additionally depends on startup versus runtime context; no
/// runtime severity may reveal UI. Dynamic copy composed at the failure site (e.g. a capture reason)
/// is passed through. Call sites reference these so the policy is centralized and unit-testable.
public extension UserFacingError {
    /// No API key on Start. Realtime voice transcription always runs on the OpenAI key — whichever
    /// brain provider is selected — so the session never comes up: fatal.
    static var noAPIKey: UserFacingError {
        .init(title: "No OpenAI API key set",
              message: "Voice transcription needs an OpenAI API key even when the brain runs on a local CLI. Open \u{201C}Settings\u{2026}\u{201D} \u{2192} Brain, paste your key, then press Start.",
              severity: .fatal)
    }

    /// The selected brain provider's CLI isn't installed (or was removed since it was selected).
    /// A *preflight* failure: the Start is refused before anything is torn down, so it must alert
    /// without stopping — an in-place restart (e.g. a key re-save while running) that trips this
    /// guard has a live session that must survive.
    static func brainCLIMissing(provider: String) -> UserFacingError {
        .init(title: "\(provider) not found",
              message: "The \(provider) command-line tool isn't installed on this Mac. Install and sign in to it, or switch the brain provider back to the OpenAI API in Settings \u{2192} Brain.",
              severity: .warning)
    }

    /// The selected CLI is installed but definitively signed out. Every brain turn would fail, so
    /// refuse the Start instead of opening a pipeline that can never coach. Same preflight semantics
    /// as `brainCLIMissing`: alert, but never stop a session that's already running.
    static func brainCLINotSignedIn(provider: String) -> UserFacingError {
        .init(title: "\(provider) isn't signed in",
              message: "Sign in by running the \(provider) command once in Terminal, or switch the brain provider in Settings \u{2192} Brain, then press Start again.",
              severity: .warning)
    }

    /// The selected CLI is installed but its status probe failed or timed out. That is not proof of
    /// being signed out, so this is a degraded notice rather than a Start blocker.
    static func brainCLISignInUnconfirmed(provider: String) -> UserFacingError {
        .init(title: "\(provider) sign-in unconfirmed",
              message: "Couldn't confirm \(provider) is signed in \u{2014} coaching turns may fail. If they do, run the CLI once in Terminal to sign in, then Stop and Start.",
              severity: .degraded)
    }

    /// The selected CLI passed preflight but an actual coaching request failed. The session cannot
    /// coach, so stop without activating the app; the Activity log gets a discreet fixed notice and
    /// the detailed reason stays in diagnostics.
    static func brainCLIStopped(provider: String, signInCommand: String,
                                reason: String) -> UserFacingError {
        .init(title: "\(provider) couldn't respond",
              message: "\(reason)\n\nCoaching has stopped. Run \u{201C}\(signInCommand)\u{201D} in Terminal, or choose another brain provider in Settings \u{2192} Brain, then Start again.",
              severity: .terminal)
    }

    /// Audio capture couldn't be built or started. `reason` is the human-readable cause from the capture
    /// layer (no input device, permission, unreadable rate, …). Fatal — there's nothing to coach from.
    static func captureFailed(reason: String) -> UserFacingError {
        .init(title: "Couldn't start audio capture", message: reason, severity: .fatal)
    }

    /// Audio capture started, then became unavailable after a route rebuild. Coaching cannot
    /// continue, but a runtime failure must stop without activating the app.
    static func captureStopped(reason: String) -> UserFacingError {
        .init(title: "Audio capture stopped", message: reason, severity: .terminal)
    }

    /// The mic ("me") transcription socket gave up (bad key / quota / network) — NOT a mic-hardware
    /// failure (that's `captureStopped`). Coaching can't continue, so stop without revealing UI.
    static var transcriptionStopped: UserFacingError {
        .init(title: "Transcription stopped",
              message: "Jarvis lost its connection to the transcription service (often a bad API key, quota, or network issue). Coaching has stopped.",
              severity: .terminal)
    }

    /// The system-audio ("them") socket gave up. The mic still works, so this is a graceful degrade —
    /// a non-blocking notice, NOT a session-ending alert.
    static var systemAudioStopped: UserFacingError {
        .init(title: "System audio stopped",
              message: "Stopped transcribing the other side's audio; your microphone is still active.",
              severity: .degraded)
    }
}
