import Foundation

/// The catalog of the app's user-facing failures: the single source of truth for each failure's
/// lifecycle consequence. Presentation additionally depends on startup versus runtime context; no
/// runtime severity may reveal UI. Dynamic copy composed at the failure site (e.g. a capture reason)
/// is passed through. Call sites reference these so the policy is centralized and unit-testable.
public extension UserFacingError {
    /// First-time setup has not selected a primary brain provider, so no route can be constructed.
    static var brainProviderNotConfigured: UserFacingError {
        .init(
            title: "Choose a provider",
            message: "Open Settings → Brain and choose a Primary provider, then press Start.",
            severity: .fatal,
            sessionEndReason: .brainProviderNotConfigured)
    }

    /// No API key on Start. Realtime voice transcription always runs on the OpenAI key — whichever
    /// brain provider is selected — so the session never comes up: fatal.
    static var noAPIKey: UserFacingError {
        .init(title: "No OpenAI API key set",
              message: "Voice transcription needs an OpenAI API key even when the brain runs on a local CLI. Open \u{201C}Settings\u{2026}\u{201D} \u{2192} Brain, paste your key, then press Start.",
              severity: .fatal,
              sessionEndReason: .openAIAPIKeyMissing)
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

    /// Jarvis requires the local agent to expose a constrained MCP surface. A CLI that cannot prove
    /// the required flags/features is unavailable rather than silently receiving prompt-shaped JSON.
    static func brainCLIMCPUnsupported(provider: String) -> UserFacingError {
        .init(title: "\(provider) needs MCP support",
              message: "Update \(provider) to a version that supports Jarvis MCP actions, or choose another brain provider in Settings → Brain.",
              severity: .warning)
    }

    /// The helper is part of the signed Jarvis bundle. Its absence is an installation failure, not a
    /// reason to widen the agent contract to a weaker transport.
    static var brainMCPHelperMissing: UserFacingError {
        .init(title: "Jarvis MCP helper missing",
              message: "Reinstall Jarvis, then press Start again. Local CLI coaching requires the bundled MCP helper.",
              severity: .warning)
    }

    /// The finite user-authorized brain route was exhausted. Individual target failures never use
    /// this terminal path; their raw detail stays diagnostic while pending work moves forward.
    static func brainRouteExhausted(
        lastProvider: BrainProvider,
        reason: String
    ) -> UserFacingError {
        .init(title: "Brain fallback route exhausted",
              message: "\(reason)\n\nCoaching stopped after every configured target was exhausted. The last target was \(lastProvider.displayName). Check Settings → Brain, then Start again.",
              severity: .terminal,
              sessionEndReason: .brainRouteExhausted(lastProvider: lastProvider))
    }

    /// Audio capture couldn't be built or started. `reason` is the human-readable cause from the capture
    /// layer (no input device, permission, unreadable rate, …). Fatal — there's nothing to coach from.
    static func captureFailed(reason: String) -> UserFacingError {
        .init(title: "Couldn't start audio capture", message: reason, severity: .fatal,
              sessionEndReason: .audioCaptureUnavailable)
    }

    /// Audio capture started, then became unavailable after a route rebuild. Coaching cannot
    /// continue, but a runtime failure must stop without activating the app.
    static func captureStopped(reason: String) -> UserFacingError {
        .init(title: "Audio capture stopped", message: reason, severity: .terminal,
              sessionEndReason: .audioCaptureUnavailable)
    }

    /// The mic ("me") transcription socket gave up (bad key / quota / network) — NOT a mic-hardware
    /// failure (that's `captureStopped`). Coaching can't continue, so stop without revealing UI.
    static func transcriptionStopped(reason: TranscriptionFailureReason) -> UserFacingError {
        .init(title: "Transcription stopped",
              message: "Jarvis could not continue because \(reason.activityDescription).",
              severity: .terminal,
              sessionEndReason: .transcriptionStopped(reason: reason))
    }

    /// The system-audio ("them") socket gave up. The mic still works, so this is a graceful degrade —
    /// a non-blocking notice, NOT a session-ending alert.
    static var systemAudioStopped: UserFacingError {
        .init(title: "System audio stopped",
              message: "Stopped transcribing the other side's audio; your microphone is still active.",
              severity: .degraded)
    }
}
