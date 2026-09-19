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

    /// True when the saved setup calls a provider whose key isn't saved, which is exactly when Start
    /// would refuse. Read through the chained store, so `OPENAI_API_KEY` or `GEMINI_API_KEY` counts.
    /// A new install calls OpenAI by default; a subscription brain with Apple Speech needs no key.
    public static func needsAPIKey(
        secrets: any SecretStore, brain: BrainPreferences, transcription: TranscriptionPreferences
    ) -> Bool {
        !transcription.provider.requiredCredentials(for: brain.route)
            .allSatisfy { secrets.apiKey(for: $0) != nil }
    }

    public static func brainProvider(for credential: Credential) -> BrainProvider {
        switch credential {
        case .openAIAPIKey: .openAI
        case .geminiAPIKey: .gemini
        }
    }

    public static func transcriptionProvider(for credential: Credential) -> TranscriptionProvider {
        switch credential {
        case .openAIAPIKey: .openAI
        case .geminiAPIKey: .gemini
        }
    }

    /// The model `adopt` makes the primary, which the key step's tile names.
    public static func brainModel(for credential: Credential) -> BrainModel {
        BrainModelCatalog.defaultModel(for: brainProvider(for: credential))
    }

    public static func transcriptionModelName(
        for credential: Credential, in preferences: TranscriptionPreferences
    ) -> String {
        switch credential {
        case .openAIAPIKey: preferences.openAIModel.displayName
        case .geminiAPIKey: preferences.geminiModel.displayName
        }
    }

    /// The defaults are OpenAI, so a Gemini-only install would have Start refuse. Fallbacks that
    /// need another key would do the same; keyless subscription fallbacks stay.
    public static func adopt(
        _ credential: Credential, brain: BrainPreferences, transcription: TranscriptionPreferences
    ) {
        brain.route = BrainRoute(
            primary: BrainTarget(
                provider: brainProvider(for: credential), modelID: brainModel(for: credential).id),
            fallbackTargets: brain.route.fallbackTargets.filter {
                $0.provider.credential == nil || $0.provider.credential == credential
            })
        transcription.provider = transcriptionProvider(for: credential)
    }
}
