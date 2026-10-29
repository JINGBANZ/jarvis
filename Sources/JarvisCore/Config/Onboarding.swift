import Foundation

// Design: wiki/architecture.md#onboarding
public enum Onboarding {
    public enum Step: Sendable, Equatable {
        case apiKey
        case permissions
    }

    /// A step already satisfied is skipped, so an install that has what it needs sees no window.
    public static func steps(needsAPIKey: Bool, holdsEveryGrant: Bool) -> [Step] {
        var steps: [Step] = []
        if needsAPIKey { steps.append(.apiKey) }
        if !holdsEveryGrant { steps.append(.permissions) }
        return steps
    }

    /// Transcription requires its own key; the brain needs at least one target with a saved key or
    /// a subscription target. Subscription health is checked separately at Start.
    /// A new install calls OpenAI by default; a subscription brain with Apple Speech needs no key.
    public static func needsAPIKey(
        secrets: any SecretStore, brain: BrainPreferences, transcription: TranscriptionPreferences
    ) -> Bool {
        if let credential = transcription.provider.ownCredential,
           secrets.apiKey(for: credential)?.isEmpty != false { return true }
        return !brain.route.targets.contains { target in
            target.provider.credential.map { secrets.apiKey(for: $0)?.isEmpty == false } ?? true
        }
    }

    /// Nil for a credential that only transcribes.
    public static func brainProvider(for credential: Credential) -> BrainProvider? {
        switch credential {
        case .openAIAPIKey: .openAI
        case .geminiAPIKey: .gemini
        case .deepgramAPIKey: nil
        }
    }

    public static func transcriptionProvider(for credential: Credential) -> TranscriptionProvider {
        switch credential {
        case .openAIAPIKey: .openAI
        case .geminiAPIKey: .gemini
        case .deepgramAPIKey: .deepgram
        }
    }

    /// The model `adopt` makes the primary, which the key step's tile names.
    public static func brainModel(for credential: Credential) -> BrainModel? {
        brainProvider(for: credential).map(BrainModelCatalog.defaultModel(for:))
    }

    public static func transcriptionModelName(
        for credential: Credential, in preferences: TranscriptionPreferences
    ) -> String {
        switch credential {
        case .openAIAPIKey: preferences.openAIModel.displayName
        case .geminiAPIKey: preferences.geminiModel.displayName
        case .deepgramAPIKey: preferences.deepgramModel.displayName
        }
    }

    /// The defaults are OpenAI, so a Gemini-only install would have Start refuse. Fallbacks that
    /// need another key would do the same; keyless subscription fallbacks stay.
    public static func adopt(
        _ credential: Credential, brain: BrainPreferences, transcription: TranscriptionPreferences
    ) {
        if let provider = brainProvider(for: credential), let model = brainModel(for: credential) {
            brain.route = BrainRoute(
                primary: BrainTarget(provider: provider, modelID: model.id),
                fallbackTargets: brain.route.fallbackTargets.filter {
                    $0.provider.credential == nil || $0.provider.credential == credential
                })
        }
        transcription.provider = transcriptionProvider(for: credential)
    }
}
