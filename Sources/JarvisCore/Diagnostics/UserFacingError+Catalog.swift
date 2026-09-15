import Foundation

/// The catalog of the app's user-facing failures: the single source of truth for each failure's
/// lifecycle consequence. Presentation additionally depends on startup versus runtime context; no
/// runtime severity may reveal UI. Dynamic copy composed at the failure site (e.g. a capture reason)
/// is passed through. Call sites reference these so the policy is centralized and unit-testable.
public extension UserFacingError {
    /// No API key on Start for the selected transcription provider or a configured brain target.
    /// Names each missing credential so a user with one valid key isn't left guessing which one is
    /// absent — e.g. Gemini transcription plus an OpenAI brain route can legitimately miss both.
    static func noAPIKey(missing: Set<Credential>) -> UserFacingError {
        // Sorted by display name for a stable, deterministic message across attempts.
        let named = missing.map(\.displayName).sorted()
        return .init(
            title: "Missing API key",
            message: "An API key is missing for \(sentenceList(named)). Open \u{201C}Settings\u{2026}\u{201D} "
                + "\u{2192} Connections, paste the missing key, then press Start.",
            severity: .fatal,
            sessionEndReason: .openAIAPIKeyMissing)
    }

    /// Apple Speech is selected on an unsupported OS/device, or its selected locale is unavailable.
    /// This is a preflight refusal, so a currently running session remains intact.
    static var appleSpeechUnavailable: UserFacingError {
        .init(
            title: "Apple Speech unavailable",
            message: "On-device transcription requires macOS 26 or later, Apple Speech support, and a supported conversation locale. Check the locale in Settings or choose OpenAI transcription.",
            severity: .warning)
    }

    /// The selected Apple model could not be downloaded or prepared. Keep raw framework/download
    /// detail in the debug log and give the explicit Start action a fixed recovery suggestion.
    static var appleSpeechPreparationFailed: UserFacingError {
        .init(
            title: "Couldn’t prepare Apple Speech",
            message: "Jarvis couldn’t prepare the selected on-device speech model. Check your network connection, locale, and available storage, then press Start again.",
            severity: .warning)
    }

    /// No target in the brain route can serve a request: each is a subscription that is signed out
    /// or whose sign-in service couldn't start. A *preflight* failure: the Start is refused before
    /// anything is torn down, so it alerts without stopping, and an in-place restart that trips it
    /// has a live session that must survive. It carries the first target's failure, whose sentence
    /// says what to do.
    static func brainRouteUnavailable(failure: ProviderFailure) -> UserFacingError {
        .init(title: "\(failure.source.displayName) isn't ready",
              message: "\(failure.activitySentence).",
              severity: .warning)
    }

    /// A permission required by the selected session is unavailable. This is distinct from capture
    /// construction: Screen Recording may be optional, and a TCC refusal has its own recovery path.
    static func permissionsMissing(
        _ missing: Set<JarvisReadiness.Permission>
    ) -> UserFacingError {
        let named = JarvisReadiness.Permission.allCases
            .filter(missing.contains)
            .map(\.displayName)
        // Screen Recording is only visible to a new process, so telling the user to press Start
        // again would send them round a loop that cannot end.
        let ending = missing.contains(.screenRecording) ? "reopen Jarvis." : "press Start again."
        let message = named.isEmpty
            ? "Check Jarvis permissions in System Settings → Privacy & Security, then \(ending)"
            : "Enable \(sentenceList(named)) in System Settings → Privacy & Security, then \(ending)"
        return .init(
            title: missing.count == 1 ? "Permission needed" : "Permissions needed",
            message: message,
            severity: .fatal,
            sessionEndReason: .permissionsMissing)
    }

    /// "A", "A and B", "A, B, and C" — the shape the permission notice reads in.
    private static func sentenceList(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        guard items.count > 2 else { return "\(items[0]) and \(items[1])" }
        return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
    }

    /// The finite user-authorized brain route was exhausted. Individual target failures never use
    /// this terminal path; they retry or advance the route while pending work moves forward.
    static func brainRouteExhausted(
        target: BrainTarget,
        failure: ProviderFailure
    ) -> UserFacingError {
        .init(title: "Brain fallback route exhausted",
              message: "\(failure.activitySentence)\n\nCoaching stopped after every configured target was exhausted. The last target was \(target.provider.displayName). Check Settings → Brain, then Start again.",
              severity: .terminal,
              sessionEndReason: .brainRouteExhausted(last: failure))
    }

    /// A streak of failed coaching cycles reached the recovery ceiling without one success. Ends as
    /// quietly as route exhaustion; Activity carries the most recent failure as the explanation.
    static func brainRecoveryExpired(failure: ProviderFailure) -> UserFacingError {
        .init(title: "Coaching stopped",
              message: "\(failure.activitySentence)\n\nCoaching kept failing for \(Int(BrainCycleRecovery.ceiling / 60)) minutes, so the session ended. Check Settings → Brain, then Start again.",
              severity: .terminal,
              sessionEndReason: .brainRecoveryExpired(last: failure))
    }

    /// Audio capture couldn't be built or started (no input device, permission, unreadable rate, …).
    /// Fatal — there's nothing to coach from.
    static func captureFailed(failure: ProviderFailure) -> UserFacingError {
        .init(title: "Couldn't start audio capture", message: failure.message, severity: .fatal,
              sessionEndReason: .audioCaptureUnavailable(failure: failure))
    }

    /// Audio capture started, then became unavailable after a route rebuild. Coaching cannot
    /// continue, but a runtime failure must stop without activating the app.
    static func captureStopped(failure: ProviderFailure) -> UserFacingError {
        .init(title: "Audio capture stopped", message: failure.message, severity: .terminal,
              sessionEndReason: .audioCaptureUnavailable(failure: failure))
    }

    /// The mic ("me") transcription endpoint gave up — NOT a mic-hardware failure (that's
    /// `captureStopped`). Coaching can't continue, so stop without revealing UI.
    static func transcriptionStopped(failure: ProviderFailure) -> UserFacingError {
        .init(title: "Transcription stopped",
              message: "Jarvis could not continue because \(failure.activitySentence).",
              severity: .terminal,
              sessionEndReason: .transcriptionStopped(failure: failure))
    }

    /// The system-audio ("them") endpoint gave up. The mic still works, so this is a graceful
    /// degrade — a non-blocking notice, NOT a session-ending alert.
    static var systemAudioStopped: UserFacingError {
        .init(title: "System audio stopped",
              message: "Stopped transcribing the other side's audio; your microphone is still active.",
              severity: .degraded)
    }
}
