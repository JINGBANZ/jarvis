import Foundation

public extension UserFacingError {
    static func noAPIKey(missing: Set<Credential>) -> UserFacingError {
        // Sorted so the message is stable across attempts.
        let named = missing.map(\.displayName).sorted()
        return .init(
            title: "Missing API key",
            message: "An API key is missing for \(sentenceList(named)). Open \u{201C}Settings\u{2026}\u{201D} "
                + "\u{2192} Connections, paste the missing key, then press Start.",
            severity: .fatal,
            sessionEndReason: .apiKeyMissing)
    }

    /// A preflight refusal, so a running session remains intact.
    static var appleSpeechUnavailable: UserFacingError {
        .init(
            title: "Apple Speech unavailable",
            message: "On-device transcription requires macOS 26 or later, Apple Speech support, and a supported conversation locale. Check the locale in Settings or choose OpenAI transcription.",
            severity: .warning)
    }

    /// Fixed copy; raw framework and download detail stays in the debug log.
    static var appleSpeechPreparationFailed: UserFacingError {
        .init(
            title: "Couldn’t prepare Apple Speech",
            message: "Jarvis couldn’t prepare the selected on-device speech model. Check your network connection, locale, and available storage, then press Start again.",
            severity: .warning)
    }

    /// A preflight failure: Start is refused before any teardown, so a live session survives.
    static func brainRouteUnavailable(failure: ProviderFailure) -> UserFacingError {
        .init(title: "\(failure.source.displayName) isn't ready",
              message: "\(failure.activitySentence).",
              severity: .warning)
    }

    static func permissionsMissing(
        _ missing: Set<JarvisReadiness.Permission>
    ) -> UserFacingError {
        let named = JarvisReadiness.Permission.allCases
            .filter(missing.contains)
            .map(\.displayName)
        // A Screen Recording grant is only visible to a new process, so Start again would loop.
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

    private static func sentenceList(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        guard items.count > 2 else { return "\(items[0]) and \(items[1])" }
        return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
    }

    static func brainRouteExhausted(
        target: BrainTarget,
        failure: ProviderFailure
    ) -> UserFacingError {
        .init(title: "Brain fallback route exhausted",
              message: "\(failure.activitySentenceWithoutAdvice)\n\nCoaching stopped after every configured target was exhausted. The last target was \(target.provider.displayName). Check Settings → Brain, then Start again.",
              severity: .terminal,
              sessionEndReason: .brainRouteExhausted(last: failure))
    }

    static func brainRecoveryExpired(failure: ProviderFailure) -> UserFacingError {
        .init(title: "Coaching stopped",
              message: "\(failure.activitySentenceWithoutAdvice)\n\nCoaching kept failing for \(Int(BrainCycleRecovery.ceiling / 60)) minutes, so the session ended. Check Settings → Brain, then Start again.",
              severity: .terminal,
              sessionEndReason: .brainRecoveryExpired(last: failure))
    }

    static func captureFailed(failure: ProviderFailure) -> UserFacingError {
        .init(title: "Couldn't start audio capture", message: failure.message, severity: .fatal,
              sessionEndReason: .audioCaptureUnavailable(failure: failure))
    }

    /// A runtime failure, so it stops without activating the app.
    static func captureStopped(failure: ProviderFailure) -> UserFacingError {
        .init(title: "Audio capture stopped", message: failure.message, severity: .terminal,
              sessionEndReason: .audioCaptureUnavailable(failure: failure))
    }

    /// The mic transcription endpoint gave up. Mic hardware failure is `captureStopped`.
    static func transcriptionStopped(failure: ProviderFailure) -> UserFacingError {
        .init(title: "Transcription stopped",
              message: "Jarvis could not continue because \(failure.activitySentence).",
              severity: .terminal,
              sessionEndReason: .transcriptionStopped(failure: failure))
    }

    static var systemAudioStopped: UserFacingError {
        .init(title: "System audio stopped",
              message: "Stopped transcribing the other side's audio; your microphone is still active.",
              severity: .degraded)
    }
}
