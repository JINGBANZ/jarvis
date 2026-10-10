import Testing
@testable import JarvisCore

@Suite struct RobotHealthTests {
    private let codex = BrainTarget(provider: .codexSubscription, modelID: "gpt-6.1-sol")
    private let openAI = BrainTarget(provider: .openAI, modelID: "gpt-6.1-sol")
    private let claude = BrainTarget(provider: .claudeSubscription, modelID: "claude-opus-5-5")

    private func health(
        _ part: RobotPart, _ inputs: RobotHubInputs = .fixture(), _ readiness: RobotReadiness = .fixture()
    ) -> RobotPartHealth {
        RobotHealth.health(of: part, inputs: inputs, readiness: readiness)
    }

    @Test func everythingConfiguredIsReady() {
        for part in RobotPart.allCases {
            #expect(health(part) == .ready)
        }
    }

    @Test func aSignedOutPrimaryWithAWorkingFallbackSaysItWillBeSkipped() {
        let inputs = RobotHubInputs.fixture(route: BrainRoute(primary: codex, fallbackTargets: [openAI]))
        let result = health(.brain, inputs, .fixture(signedOut: [.codexSubscription]))
        #expect(result.reason == "PRIMARY UNAVAILABLE")
        #expect(result.tone == .attention)
        #expect(result.advice?.contains("OpenAI API") == true)
        #expect(result.advice?.contains("Sign in again") == true)
        #expect(result.fix == .openConnections)
    }

    @Test func aRouteNobodyCanServeSaysSo() {
        let inputs = RobotHubInputs.fixture(route: BrainRoute(primary: codex, fallbackTargets: [claude]))
        let readiness = RobotReadiness.fixture(signedOut: [.codexSubscription, .claudeSubscription])
        let result = health(.brain, inputs, readiness)
        #expect(result.reason == "NO BRAIN AVAILABLE")
        #expect(result.tone == .blocked)
        #expect(result.advice?.contains("Codex") == true)
        #expect(result.advice?.contains("No configured fallback") == true)
        #expect(result.fix == .openConnections)
    }

    @Test func anOpenAIPrimaryNeedsAKey() {
        let inputs = RobotHubInputs.fixture(route: BrainRoute(primary: openAI, fallbackTargets: [codex]))
        let result = health(.brain, inputs, .fixture(credentials: []))
        #expect(result.reason == "PRIMARY UNAVAILABLE")
        #expect(result.tone == .attention)
        #expect(result.advice?.contains(Credential.openAIAPIKey.displayName) == true)
        #expect(result.advice?.contains("Codex") == true)
        #expect(result.fix == .openConnections)
    }

    @Test func anOpenAIFallbackWithoutAKeyDoesNotBlockAUsablePrimary() {
        let inputs = RobotHubInputs.fixture(route: BrainRoute(primary: codex, fallbackTargets: [openAI]))
        #expect(health(.brain, inputs, .fixture(credentials: [])) == .ready)
    }

    @Test func aGeminiTargetNeedsTheGeminiKey() {
        let gemini = BrainTarget(provider: .gemini, modelID: "gemini-3.8-flash")
        let inputs = RobotHubInputs.fixture(route: BrainRoute(primary: codex, fallbackTargets: [gemini]))
        #expect(health(.brain, inputs, .fixture(credentials: [.openAIAPIKey])) == .ready)
        #expect(health(.brain, inputs, .fixture(credentials: [.geminiAPIKey])) == .ready)
    }

    @Test func aSignedOutFallbackAloneKeepsTheBrainReady() {
        let inputs = RobotHubInputs.fixture(route: BrainRoute(primary: openAI, fallbackTargets: [codex]))
        #expect(health(.brain, inputs, .fixture(signedOut: [.codexSubscription])) == .ready)
    }

    @Test func aMissingFallbackKeyDoesNotCountAsAWorkingFallback() {
        let inputs = RobotHubInputs.fixture(route: BrainRoute(primary: codex, fallbackTargets: [openAI]))
        let result = health(.brain, inputs, .fixture(signedOut: [.codexSubscription], credentials: []))
        #expect(result.reason == "NO BRAIN AVAILABLE")
        #expect(result.tone == .blocked)
        #expect(result.advice?.contains("No configured fallback") == true)
        #expect(result.fix == .openConnections)
    }

    @Test(arguments: [ProviderFailure.Category.authentication, .unavailable, .quota, .configuration])
    func allUnavailablePrimaryCausesUseTheConfiguredFallback(category: ProviderFailure.Category) {
        let failure = ProviderFailure(
            source: .brain(.claudeSubscription), stage: .process, category: category,
            disposition: .temporary, identity: .init(), message: "Cannot serve right now.")
        var readiness = RobotReadiness.fixture()
        readiness.subscriptions[.claudeSubscription] = .unavailable(failure)
        let inputs = RobotHubInputs.fixture(route: BrainRoute(primary: claude, fallbackTargets: [openAI]))
        let result = health(.brain, inputs, readiness)
        #expect(result.reason == "PRIMARY UNAVAILABLE")
        #expect(result.tone == .attention)
        #expect(result.advice?.contains(failure.activitySentence) == true)
        #expect(result.advice?.contains("OpenAI API") == true)
    }

    @Test func uncheckedSubscriptionsShowCheckingUntilAUsableRouteIsKnown() {
        var readiness = RobotReadiness.fixture()
        readiness.subscriptions[.claudeSubscription] = nil
        #expect(health(.brain, .fixture(route: BrainRoute(primary: claude, fallbackTargets: [])), readiness) == .checking)
        readiness.subscriptions[.codexSubscription] = RobotReadiness.fixture(signedOut: [.codexSubscription])
            .subscriptions[.codexSubscription]
        #expect(health(.brain, .fixture(route: BrainRoute(primary: codex, fallbackTargets: [claude])), readiness) == .checking)
        #expect(health(.brain, .fixture(route: BrainRoute(primary: openAI, fallbackTargets: [claude])), readiness) == .ready)
    }

    @Test func earNeedsItsProvidersKeyFirst() {
        let inputs = RobotHubInputs.fixture(transcriptionProvider: .gemini)
        #expect(health(.ear, inputs, .fixture(credentials: [.openAIAPIKey], granted: [])) == .needsAttention(
            reason: "ADD A GEMINI KEY",
            advice: "I need your Gemini key to hear the conversation. Add it in Connections.",
            fix: .openConnections))
    }

    @Test func earNeedsTheMicrophone() {
        let inputs = RobotHubInputs.fixture(transcriptionProvider: .appleSpeech)
        #expect(health(.ear, inputs, .fixture(granted: [.screenRecording])) == .needsAttention(
            reason: "MICROPHONE IS OFF",
            advice: "Microphone access is off. Turn it on in System Settings, Privacy & Security.",
            fix: nil))
    }

    @Test func eyeNeedsScreenRecording() {
        #expect(health(.eye, .fixture(), .fixture(granted: [.microphone])) == .needsAttention(
            reason: "SCREEN RECORDING IS OFF",
            advice: "Screen Recording is off, so I can't see your screen. Turn it on in System Settings, Privacy & Security, then reopen me.",
            fix: nil))
    }
}
