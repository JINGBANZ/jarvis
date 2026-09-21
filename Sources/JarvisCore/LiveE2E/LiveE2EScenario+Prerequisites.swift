#if JARVIS_LIVE_E2E
extension LiveE2EScenario {
    public var requiredBrainProviders: Set<BrainProvider> {
        Set([brain.primary] + brain.fallbacks + steps.compactMap { step in
            if case .switchBrain(let provider) = step { provider } else { nil }
        })
    }

    public var requiredCredentials: Set<Credential> {
        var credentials = Set(requiredBrainProviders.compactMap(\.credential))
        if transcription.key == .standard { credentials.insert(.openAIAPIKey) }
        return credentials
    }
}
#endif
