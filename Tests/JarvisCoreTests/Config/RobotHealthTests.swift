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
        #expect(health(.brain, inputs, .fixture(signedOut: [.codexSubscription])) == .needsAttention(
            reason: "CODEX IS SIGNED OUT",
            advice: "Codex is signed out. I'll skip it and use the next brain in the route until you sign in again.",
            fix: .openConnections))
    }

    @Test func aRouteNobodyCanServeSaysSo() {
        let inputs = RobotHubInputs.fixture(route: BrainRoute(primary: codex, fallbackTargets: [claude]))
        let readiness = RobotReadiness.fixture(signedOut: [.codexSubscription, .claudeSubscription])
        #expect(health(.brain, inputs, readiness) == .needsAttention(
            reason: "CODEX IS SIGNED OUT",
            advice: "No brain in the route can answer right now. Sign in again in Connections, then Start again.",
            fix: .openConnections))
    }

    @Test func anOpenAIPrimaryNeedsAKey() {
        let inputs = RobotHubInputs.fixture(route: BrainRoute(primary: openAI, fallbackTargets: [codex]))
        #expect(health(.brain, inputs, .fixture(credentials: [])) == .needsAttention(
            reason: "ADD AN OPENAI KEY",
            advice: "My primary brain needs an OpenAI key. I'll skip it and use the next brain in the route. Add it in Connections.",
            fix: .openConnections))
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
        #expect(health(.brain, inputs, .fixture(signedOut: [.codexSubscription], credentials: [])) == .needsAttention(
            reason: "CODEX IS SIGNED OUT",
            advice: "No brain in the route can answer right now. Sign in again in Connections, then Start again.",
            fix: .openConnections))
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
