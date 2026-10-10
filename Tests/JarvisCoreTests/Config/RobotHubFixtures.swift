@testable import JarvisCore

extension RobotHubInputs {
    static func fixture(
        route: BrainRoute = BrainRoute(
            primary: BrainTarget(provider: .codexSubscription, modelID: "gpt-6.1-sol"), fallbackTargets: []),
        effort: ReasoningEffort = .high,
        transcriptionProvider: TranscriptionProvider = .openAI,
        readiness: RobotReadiness? = nil,
        activeTarget: BrainTarget? = nil
    ) -> RobotHubInputs {
        RobotHubInputs(
            route: route,
            effort: effort,
            transcription: TranscriptionConfiguration(
                provider: transcriptionProvider,
                openAIModel: .gpt4oTranscribe,
                openAIExpectedLanguages: [.english],
                appleSpeechLocaleIdentifier: "en_US"),
            screenScope: .activeWindow,
            displayIndex: 1,
            browserTextEnabled: false,
            boxFontSize: 25,
            readiness: readiness,
            activeTarget: activeTarget)
    }
}

extension RobotReadiness {
    static func fixture(
        signedOut: Set<BrainProvider> = [],
        credentials: Set<Credential> = [.openAIAPIKey, .geminiAPIKey],
        granted: Set<JarvisReadiness.Permission> = [.microphone, .screenRecording]
    ) -> RobotReadiness {
        let subscriptions = Dictionary(uniqueKeysWithValues: BrainProvider.allCases.filter(\.servedByLocalProxy).map {
            provider -> (BrainProvider, ConnectionHealth) in
            let health: ConnectionHealth = signedOut.contains(provider) ? .unavailable(ProviderFailure(
                source: .brain(provider), stage: .process, category: .authentication,
                disposition: .permanent, identity: .init(), message: "Sign in again in Connections.")) : .ready
            return (provider, health)
        })
        return RobotReadiness(
            subscriptions: subscriptions,
            availableCredentials: credentials,
            grantedPermissions: granted)
    }
}
