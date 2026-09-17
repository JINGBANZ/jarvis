import Testing
@testable import JarvisCore

@Suite struct UserFacingErrorCatalogTests {
    @Test func noAPIKeyIsFatalAndNamesTheMissingCredential() {
        let geminiOnly = UserFacingError.noAPIKey(missing: [.geminiAPIKey])
        #expect(geminiOnly.message.contains("Gemini API"))
        #expect(!geminiOnly.message.contains("OpenAI"))

        let openAIOnly = UserFacingError.noAPIKey(missing: [.openAIAPIKey])
        #expect(openAIOnly.message.contains("OpenAI API"))
        #expect(!openAIOnly.message.contains("Gemini"))

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

        let all = UserFacingError.permissionsMissing([.screenRecording, .systemAudio, .microphone])
        #expect(all.title == "Permissions needed")
        #expect(all.message.contains("Microphone, System Audio Recording, and Screen Recording"))
    }

    @Test func aMissingScreenGrantAsksForARelaunchRatherThanAnotherStart() {
        // macOS applies a Screen Recording grant only to a new process, so Start again would loop.
        let screen = UserFacingError.permissionsMissing([.screenRecording])
        #expect(screen.message.contains("reopen Jarvis"))
        #expect(!screen.message.contains("press Start again"))

        #expect(UserFacingError.permissionsMissing([.microphone]).message
            .contains("press Start again"))
    }

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
        #expect(UserFacingError.systemAudioStopped.severity == .degraded)
        #expect(!UserFacingError.systemAudioStopped.severity.showsAlert)
        #expect(!UserFacingError.systemAudioStopped.severity.stopsSession)
    }

    @Test func anUnavailableRouteAlertsWithoutStoppingAndSaysWhatToDo() {
        let failure = ProviderFailure(
            source: .brain(.claudeSubscription), stage: .process, category: .authentication,
            disposition: .permanent, identity: .init(), message: "")
        let e = UserFacingError.brainRouteUnavailable(failure: failure)
        #expect(e.severity == .warning)
        #expect(e.severity.showsAlert)
        #expect(!e.severity.stopsSession)
        #expect(e.title == "Claude Code isn't ready")
        #expect(e.message
            == "Claude Code isn't signed in; open Settings → Connections, press Sign in for it, then press Start.")
    }

    @Test func exhaustedBrainRouteStopsQuietlyAndKeepsDiagnosticDetail() {
        let failure = ProviderFailure(
            source: .brain(.claudeSubscription), stage: .process, category: .unknown,
            disposition: .temporary, identity: .init(), message: "OAuth session expired")
        let e = UserFacingError.brainRouteExhausted(
            target: BrainTarget(
                provider: .claudeSubscription,
                modelID: BrainModelCatalog.defaultModel(for: .claudeSubscription).id),
            failure: failure)
        #expect(e.severity == .terminal)
        #expect(!e.severity.showsAlert)
        #expect(e.severity.stopsSession)
        #expect(e.title.contains("route exhausted"))
        #expect(e.message.contains("OAuth session expired"))
        #expect(e.message.contains("Claude Code"))
        #expect(e.sessionEndReason == .brainRouteExhausted(last: failure))
    }

    @Test func expiredBrainRecoveryStopsQuietlyAndCarriesTheLatestFailure() {
        let failure = ProviderFailure(
            source: .brain(.openAI), stage: .request, category: .unavailable,
            disposition: .temporary, identity: .init(), message: "upstream overloaded")
        let e = UserFacingError.brainRecoveryExpired(failure: failure)
        #expect(e.severity == .terminal)
        #expect(!e.severity.showsAlert)
        #expect(e.severity.stopsSession)
        #expect(e.message.contains("upstream overloaded"))
        #expect(e.message.contains("10 minutes"))
        #expect(e.sessionEndReason == .brainRecoveryExpired(last: failure))
    }
}
