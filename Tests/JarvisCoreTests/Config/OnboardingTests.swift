import Foundation
import Testing
@testable import JarvisCore

@Suite struct OnboardingTests {
    private struct SavedKeys: SecretStore {
        let keys: [Credential: String]
        func apiKey(for credential: Credential) -> String? { keys[credential] }
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "OnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func defaultTarget(_ provider: BrainProvider) -> BrainTarget {
        BrainTarget(provider: provider, modelID: BrainModelCatalog.defaultModel(for: provider).id)
    }

    @Test func onlyWhatIsMissingBecomesAStep() {
        #expect(Onboarding.steps(needsAPIKey: true, holdsEveryGrant: false) == [.apiKey, .permissions])
        #expect(Onboarding.steps(needsAPIKey: false, holdsEveryGrant: false) == [.permissions])
        #expect(Onboarding.steps(needsAPIKey: true, holdsEveryGrant: true) == [.apiKey])
        #expect(Onboarding.steps(needsAPIKey: false, holdsEveryGrant: true).isEmpty)
    }

    @Test func aNewInstallNeedsTheKeyItsSetupCalls() {
        let defaults = freshDefaults()
        let brain = BrainPreferences(defaults: defaults)
        let transcription = TranscriptionPreferences(defaults: defaults)
        #expect(Onboarding.needsAPIKey(
            secrets: SavedKeys(keys: [:]), brain: brain, transcription: transcription))
        #expect(!Onboarding.needsAPIKey(
            secrets: SavedKeys(keys: [.openAIAPIKey: "sk-1"]), brain: brain, transcription: transcription))
        // The other vendor's key alone would leave Start refusing, so the step still shows.
        #expect(Onboarding.needsAPIKey(
            secrets: SavedKeys(keys: [.geminiAPIKey: "AIza-1"]), brain: brain, transcription: transcription))
    }

    @Test func aGeminiSetupIsSatisfiedByItsOwnKey() {
        let defaults = freshDefaults()
        let brain = BrainPreferences(defaults: defaults)
        let transcription = TranscriptionPreferences(defaults: defaults)
        Onboarding.adopt(.geminiAPIKey, brain: brain, transcription: transcription)
        #expect(!Onboarding.needsAPIKey(
            secrets: SavedKeys(keys: [.geminiAPIKey: "AIza-1"]), brain: brain, transcription: transcription))
    }

    @Test func aKeylessSetupNeedsNoKey() {
        let defaults = freshDefaults()
        let brain = BrainPreferences(defaults: defaults)
        let transcription = TranscriptionPreferences(defaults: defaults)
        brain.route = BrainRoute(primary: defaultTarget(.claudeSubscription), fallbackTargets: [])
        transcription.provider = .appleSpeech
        #expect(!Onboarding.needsAPIKey(
            secrets: SavedKeys(keys: [:]), brain: brain, transcription: transcription))
    }

    @Test func anEnvironmentKeyCounts() {
        let defaults = freshDefaults()
        let secrets = ChainedSecretStore([
            SavedKeys(keys: [:]),
            EnvSecretStore(environment: ["OPENAI_API_KEY": "sk-1"]),
        ])
        #expect(!Onboarding.needsAPIKey(
            secrets: secrets,
            brain: BrainPreferences(defaults: defaults),
            transcription: TranscriptionPreferences(defaults: defaults)))
    }

    @Test func everyCredentialPowersABrainAndAnEar() {
        for credential in Credential.allCases {
            #expect(Onboarding.brainProvider(for: credential).credential == credential)
            #expect(Onboarding.transcriptionProvider(for: credential).ownCredential == credential)
        }
    }

    @Test func tilesNameTheModelsAdoptionWouldUse() {
        let transcription = TranscriptionPreferences(defaults: freshDefaults())
        #expect(Onboarding.brainModel(for: .geminiAPIKey) == BrainModelCatalog.defaultModel(for: .gemini))
        #expect(Onboarding.transcriptionModelName(for: .openAIAPIKey, in: transcription)
            == Defaults.Transcription.openAIModel.displayName)
        #expect(Onboarding.transcriptionModelName(for: .geminiAPIKey, in: transcription)
            == Defaults.Transcription.geminiModel.displayName)
    }

    @Test func adoptingGeminiMakesItTheBrainAndTheEar() {
        let defaults = freshDefaults()
        let brain = BrainPreferences(defaults: defaults)
        let transcription = TranscriptionPreferences(defaults: defaults)

        Onboarding.adopt(.geminiAPIKey, brain: brain, transcription: transcription)

        #expect(brain.route.primary == defaultTarget(.gemini))
        #expect(transcription.provider == .gemini)
        #expect(transcription.provider.requiredCredentials(for: brain.route) == [.geminiAPIKey])
    }

    @Test func adoptingKeepsKeylessFallbacksAndDropsOnesNeedingAnotherKey() {
        let defaults = freshDefaults()
        let brain = BrainPreferences(defaults: defaults)
        brain.fallbackTargets = [defaultTarget(.codexSubscription), defaultTarget(.gemini)]

        Onboarding.adopt(.openAIAPIKey, brain: brain, transcription: TranscriptionPreferences(defaults: defaults))

        #expect(brain.route.primary == defaultTarget(.openAI))
        #expect(brain.route.fallbackTargets == [defaultTarget(.codexSubscription)])
    }
}
