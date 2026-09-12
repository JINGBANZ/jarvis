import Testing
@testable import JarvisCore

/// The catalog is the single source of truth for *which* failures are loud. These tests lock in the
/// loudness of each canonical failure so a regression (e.g. silently downgrading a capture failure, or
/// making the graceful "them"-socket degrade pop a modal) is caught without a UI session.
@Suite struct UserFacingErrorCatalogTests {
    @Test func noAPIKeyIsFatalAndNamesTheMissingCredential() {
        // A single missing Gemini key must name Gemini, not send the user hunting through both
        // providers — this is the defect the spec calls out.
        let geminiOnly = UserFacingError.noAPIKey(missing: [.geminiAPIKey])
        #expect(geminiOnly.message.contains("Gemini API"))
        #expect(!geminiOnly.message.contains("OpenAI"))

        let openAIOnly = UserFacingError.noAPIKey(missing: [.openAIAPIKey])
        #expect(openAIOnly.message.contains("OpenAI API"))
        #expect(!openAIOnly.message.contains("Gemini"))

        // Gemini transcription plus an OpenAI-only brain route can legitimately miss both at once;
        // the message must name both, in a stable (sorted) order regardless of set iteration order.
        let both = UserFacingError.noAPIKey(missing: [.geminiAPIKey, .openAIAPIKey])
        #expect(both.message.contains("Gemini API and OpenAI API"))

        #expect(geminiOnly.message.contains("Connections"))
        #expect(geminiOnly.severity == .fatal)
        #expect(geminiOnly.severity.showsAlert)
        #expect(geminiOnly.sessionEndReason == .openAIAPIKeyMissing)
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

    @Test func aMissingScreenGrantAsksForARelaunchRatherThanAnotherStart() {
        // The grant only becomes visible to a new process, so "press Start again" would loop.
        let screen = UserFacingError.permissionsMissing([.screenRecording])
        #expect(screen.message.contains("reopen Jarvis"))
        #expect(!screen.message.contains("press Start again"))

        #expect(UserFacingError.permissionsMissing([.microphone]).message
            .contains("press Start again"))
    }

    /// What the capture layer records when the aggregate device goes away.
    private static let noInputDevice = ProviderFailure(
        source: .capture, stage: .local, category: .unavailable, disposition: .permanent,
        identity: .init(), message: "no input device")

    @Test func captureFailedIsFatalAndCarriesReason() {
        let e = UserFacingError.captureFailed(failure: Self.noInputDevice)
        #expect(e.severity == .fatal)
        #expect(e.severity.stopsSession)
        #expect(e.message.contains("no input device"))
        #expect(e.sessionEndReason == .audioCaptureUnavailable(failure: Self.noInputDevice))
    }

    @Test func runtimeCaptureFailureStopsQuietlyAndCarriesReason() {
        let e = UserFacingError.captureStopped(failure: Self.noInputDevice)
        #expect(e.severity == .terminal)
        #expect(e.severity.stopsSession)
        #expect(!e.severity.showsAlert)
        #expect(e.message.contains("no input device"))
        #expect(e.sessionEndReason == .audioCaptureUnavailable(failure: Self.noInputDevice))
    }

    /// Whatever a transcription boundary reports, the stop is terminal and quiet, and the message is
    /// the failure's own sentence, so the alert-free stop still says what happened.
    @Test func transcriptionStoppedIsTerminal() {
        for category in ProviderFailure.Category.allCases {
            let failure = ProviderFailure(
                source: .transcription(.openAI), stage: .session, category: category,
                disposition: .permanent, identity: .init(closeCode: 3000),
                message: "Incorrect API key provided: sk-abc123456789")
            let error = UserFacingError.transcriptionStopped(failure: failure)
            #expect(error.severity == .terminal)
            #expect(error.severity.stopsSession)
            #expect(!error.severity.showsAlert)
            #expect(error.message == "Jarvis could not continue because \(failure.activitySentence).")
            #expect(!error.message.contains("sk-abc123456789"))
            #expect(error.sessionEndReason == .transcriptionStopped(failure: failure))
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
        let failure = ProviderFailure(
            source: .brain(.claudeCode), stage: .process, category: .unknown,
            disposition: .temporary, identity: .init(), message: "OAuth session expired")
        let e = UserFacingError.brainRouteExhausted(
            target: BrainTarget(
                provider: .claudeCode,
                modelID: BrainModelCatalog.defaultModel(for: .claudeCode).id),
            failure: failure)
        #expect(e.severity == .terminal)
        #expect(!e.severity.showsAlert)
        #expect(e.severity.stopsSession)
        #expect(e.title.contains("route exhausted"))
        #expect(e.message.contains("OAuth session expired"))
        #expect(e.message.contains("Claude Code"))
        #expect(e.sessionEndReason == .brainRouteExhausted(last: failure))
    }
}
