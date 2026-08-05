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

    @Test func absentSelectionUsesCompatibilityAndAutomaticDefaults() {
        let preferences = TranscriptionPreferences(defaults: freshDefaults())
        #expect(preferences.provider == .openAI)
        #expect(preferences.openAIModel == .gpt4oTranscribe)
        #expect(preferences.openAILanguageProfile == .automatic)
        #expect(preferences.appleSpeechLocaleIdentifier == Locale.current.identifier)
    }

    @Test func selectionsRoundTripThroughDefaults() {
        let defaults = freshDefaults()
        let written = TranscriptionPreferences(defaults: defaults)
        written.provider = .appleSpeech
        written.openAIModel = .gptLiveTranscribe
        written.openAILanguageProfile = .englishAndMandarinChinese
        written.appleSpeechLocaleIdentifier = "zh-CN"

        let read = TranscriptionPreferences(defaults: defaults)
        #expect(read.provider == .appleSpeech)
        #expect(read.openAIModel == .gptLiveTranscribe)
        #expect(read.openAILanguageProfile == .englishAndMandarinChinese)
        #expect(read.appleSpeechLocaleIdentifier == "zh-CN")
        #expect(read.configuration == TranscriptionConfiguration(
            provider: .appleSpeech,
            openAIModel: .gptLiveTranscribe,
            openAILanguageProfile: .englishAndMandarinChinese,
            appleSpeechLocaleIdentifier: "zh-CN"))
    }

    @Test func unknownSelectionsUseSafeDefaults() {
        let defaults = freshDefaults()
        defaults.set("future-provider", forKey: "transcription.provider")
        defaults.set("future-model", forKey: "transcription.openai.model")
        defaults.set(
            "future-profile",
            forKey: "transcription.openai.language-profile")
        let preferences = TranscriptionPreferences(defaults: defaults)
        #expect(preferences.provider == .openAI)
        #expect(preferences.openAIModel == .gpt4oTranscribe)
        #expect(preferences.openAILanguageProfile == .automatic)
    }

    @Test func displayNamesAndCredentialRequirementsAreStable() {
        #expect(TranscriptionProvider.openAI.displayName == "OpenAI")
        #expect(TranscriptionProvider.openAI.requiresOpenAIAPIKey)
        #expect(TranscriptionProvider.appleSpeech.displayName == "Apple Speech")
        #expect(!TranscriptionProvider.appleSpeech.requiresOpenAIAPIKey)
        #expect(OpenAITranscriptionModel.gpt4oTranscribe.displayName
                == "GPT-4o Transcribe")
        #expect(OpenAITranscriptionModel.gptLiveTranscribe.displayName
                == "GPT Live Transcribe")
        #expect(OpenAITranscriptionLanguageProfile.englishAndMandarinChinese.displayName
                == "English + Mandarin Chinese")
        #expect(OpenAITranscriptionModel.gpt4oTranscribe.turnDetectionStrategy == .serverVAD)
        #expect(OpenAITranscriptionModel.gptLiveTranscribe.turnDetectionStrategy == .clientCommit)
    }

    @Test func turnStrategyAppliesOnlyToOpenAIConfiguration() {
        let openAI = TranscriptionConfiguration(
            provider: .openAI,
            openAIModel: .gptLiveTranscribe,
            openAILanguageProfile: .automatic,
            appleSpeechLocaleIdentifier: "en-US")
        let apple = TranscriptionConfiguration(
            provider: .appleSpeech,
            openAIModel: .gptLiveTranscribe,
            openAILanguageProfile: .automatic,
            appleSpeechLocaleIdentifier: "en-US")

        #expect(openAI.turnDetectionStrategy == .clientCommit)
        #expect(apple.turnDetectionStrategy == nil)
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
