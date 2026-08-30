import Testing
@testable import JarvisCore

/// The catalog is the single source of truth for *which* failures are loud. These tests lock in the
/// loudness of each canonical failure so a regression (e.g. silently downgrading a capture failure, or
/// making the graceful "them"-socket degrade pop a modal) is caught without a UI session.
@Suite struct UserFacingErrorCatalogTests {
    @Test func noAPIKeyIsFatal() {
        #expect(UserFacingError.noAPIKey.severity == .fatal)
        #expect(UserFacingError.noAPIKey.severity.showsAlert)
        #expect(UserFacingError.noAPIKey.message.contains("transcription provider or brain route"))
        #expect(UserFacingError.noAPIKey.message.contains("Connections"))
        #expect(UserFacingError.noAPIKey.sessionEndReason == .openAIAPIKeyMissing)
    }

    @Test func appleSpeechPreflightFailuresAlertWithoutStopping() {
        for error in [
            UserFacingError.appleSpeechUnavailable,
            UserFacingError.appleSpeechPreparationFailed,
        ] {
            #expect(error.severity == .warning)
            #expect(error.severity.showsAlert)
            #expect(!error.severity.stopsSession)
            #expect(error.sessionEndReason == nil)
        }
    }

    @Test func missingPermissionsAreNotClassifiedAsCaptureFailure() {
        let microphone = UserFacingError.permissionsMissing([.microphone])
        #expect(microphone.title == "Permission needed")
        #expect(microphone.message.contains("Enable Microphone"))
        #expect(!microphone.message.contains("Screen Recording"))
        #expect(microphone.severity == .fatal)
        #expect(microphone.sessionEndReason == .permissionsMissing)

        let both = UserFacingError.permissionsMissing([.microphone, .screenRecording])
        #expect(both.title == "Permissions needed")
        #expect(both.message.contains("Microphone and Screen Recording"))
        #expect(both.sessionEndReason == .permissionsMissing)
    }

    @Test func missingPermissionsAreNamedIndividuallyAndListed() {
        let systemAudio = UserFacingError.permissionsMissing([.systemAudio])
        #expect(systemAudio.title == "Permission needed")
        #expect(systemAudio.message.contains("Enable System Audio Recording in System Settings"))
        #expect(!systemAudio.message.contains("Microphone"))

        // Named in one stable order, so the notice never reshuffles between attempts.
        let all = UserFacingError.permissionsMissing([.screenRecording, .systemAudio, .microphone])
        #expect(all.title == "Permissions needed")
        #expect(all.message.contains("Microphone, System Audio Recording, and Screen Recording"))
    }

    @Test func captureFailedIsFatalAndCarriesReason() {
        let e = UserFacingError.captureFailed(reason: "no input device")
        #expect(e.severity == .fatal)
        #expect(e.severity.stopsSession)
        #expect(e.message.contains("no input device"))
        #expect(e.sessionEndReason == .audioCaptureUnavailable)
    }

    @Test func runtimeCaptureFailureStopsQuietlyAndCarriesReason() {
        let e = UserFacingError.captureStopped(reason: "route disappeared")
        #expect(e.severity == .terminal)
        #expect(e.severity.stopsSession)
        #expect(!e.severity.showsAlert)
        #expect(e.message.contains("route disappeared"))
        #expect(e.sessionEndReason == .audioCaptureUnavailable)
    }

    @Test func transcriptionStoppedIsTerminal() {
        for reason in TranscriptionFailureReason.allCases {
            let error = UserFacingError.transcriptionStopped(reason: reason)
            #expect(error.severity == .terminal)
            #expect(error.severity.stopsSession)
            #expect(!error.severity.showsAlert)
            #expect(error.message.contains(reason.activityDescription))
            #expect(error.sessionEndReason == .transcriptionStopped(reason: reason))
        }
    }

    @Test func systemAudioStoppedStaysQuiet() {
        // The graceful degrade: mic still works, so this must NOT alert or stop the session.
        #expect(UserFacingError.systemAudioStopped.severity == .degraded)
        #expect(!UserFacingError.systemAudioStopped.severity.showsAlert)
        #expect(!UserFacingError.systemAudioStopped.severity.stopsSession)
    }

    @Test func brainCLIMissingAlertsWithoutStoppingAndNamesTheProvider() {
        // A preflight refusal: the Start never opened anything, and an in-place restart that trips
        // it has a LIVE session that must survive — alert, never stop.
        let e = UserFacingError.brainCLIMissing(provider: "Claude Code")
        #expect(e.severity == .warning)
        #expect(e.severity.showsAlert)
        #expect(!e.severity.stopsSession)
        #expect(e.title.contains("Claude Code"))
    }

    @Test func brainCLINotSignedInAlertsWithoutStopping() {
        // An authoritative signed-out marker (Codex) refuses the Start — same preflight semantics.
        let e = UserFacingError.brainCLINotSignedIn(provider: "Codex CLI")
        #expect(e.severity == .warning)
        #expect(e.severity.showsAlert)
        #expect(!e.severity.stopsSession)
    }

    @Test func brainCLISignInUnconfirmedStaysQuiet() {
        // A failed/timed-out probe is unknown rather than proof of logout, so warn without blocking.
        let e = UserFacingError.brainCLISignInUnconfirmed(provider: "Claude Code")
        #expect(e.severity == .degraded)
        #expect(!e.severity.showsAlert)
        #expect(!e.severity.stopsSession)
    }

    @Test func exhaustedBrainRouteStopsQuietlyAndKeepsDiagnosticDetail() {
        let e = UserFacingError.brainRouteExhausted(
            lastProvider: .claudeCode,
            reason: "OAuth session expired")
        #expect(e.severity == .terminal)
        #expect(!e.severity.showsAlert)
        #expect(e.severity.stopsSession)
        #expect(e.title.contains("route exhausted"))
        #expect(e.message.contains("OAuth session expired"))
        #expect(e.message.contains("Claude Code"))
        #expect(e.sessionEndReason == .brainRouteExhausted(lastProvider: .claudeCode))
    }
}
