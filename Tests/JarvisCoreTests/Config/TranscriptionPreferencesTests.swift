import Foundation
import Testing
@testable import JarvisCore

@Suite struct TranscriptionPreferencesTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "TranscriptionPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func absentSelectionPreservesTheOpenAIDefault() {
        #expect(TranscriptionPreferences(defaults: freshDefaults()).provider == .openAI)
    }

    @Test func providerRoundTripsThroughDefaults() {
        let defaults = freshDefaults()
        TranscriptionPreferences(defaults: defaults).provider = .appleSpeech
        #expect(TranscriptionPreferences(defaults: defaults).provider == .appleSpeech)
    }

    @Test func unknownSelectionFailsBackToOpenAI() {
        let defaults = freshDefaults()
        defaults.set("future-provider", forKey: "transcription.provider")
        #expect(TranscriptionPreferences(defaults: defaults).provider == .openAI)
    }

    @Test func displayNamesAndCredentialRequirementsAreStable() {
        #expect(TranscriptionProvider.openAI.displayName == "OpenAI")
        #expect(TranscriptionProvider.openAI.requiresOpenAIAPIKey)
        #expect(TranscriptionProvider.appleSpeech.displayName == "Apple Speech")
        #expect(!TranscriptionProvider.appleSpeech.requiresOpenAIAPIKey)
    }

    @Test func openAIKeyRequirementCombinesTranscriptionAndBrainRoute() {
        let cliOnly = BrainRoute(
            primary: BrainTarget(provider: .claudeCode, modelID: "claude-opus-5"),
            fallbackTargets: [])
        let routeWithOpenAIFallback = BrainRoute(
            primary: cliOnly.primary,
            fallbackTargets: [
                BrainTarget(provider: .openAI, modelID: "gpt-5.4"),
            ])

        #expect(TranscriptionProvider.openAI.requiresOpenAIAPIKey(for: cliOnly))
        #expect(!TranscriptionProvider.appleSpeech.requiresOpenAIAPIKey(for: cliOnly))
        #expect(TranscriptionProvider.appleSpeech.requiresOpenAIAPIKey(
            for: routeWithOpenAIFallback))
    }
}
