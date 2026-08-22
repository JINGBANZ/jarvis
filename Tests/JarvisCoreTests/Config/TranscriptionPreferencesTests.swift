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
        #expect(preferences.openAIExpectedLanguages.isEmpty)
        #expect(preferences.appleSpeechLocaleIdentifier == Locale.current.identifier)
    }

    @Test func selectionsRoundTripThroughDefaults() {
        let defaults = freshDefaults()
        let written = TranscriptionPreferences(defaults: defaults)
        written.provider = .appleSpeech
        written.openAIModel = .gptLiveTranscribe
        written.openAIExpectedLanguages = [.mandarinChinese, .english, .mandarinChinese]
        written.appleSpeechLocaleIdentifier = "zh-CN"

        let read = TranscriptionPreferences(defaults: defaults)
        #expect(read.provider == .appleSpeech)
        #expect(read.openAIModel == .gptLiveTranscribe)
        #expect(read.openAIExpectedLanguages == [.english, .mandarinChinese])
        #expect(read.appleSpeechLocaleIdentifier == "zh-CN")
        #expect(read.configuration == TranscriptionConfiguration(
            provider: .appleSpeech,
            openAIModel: .gptLiveTranscribe,
            openAIExpectedLanguages: [.english, .mandarinChinese],
            appleSpeechLocaleIdentifier: "zh-CN"))
    }

    @Test func gptTranscribeSelectionRoundTripsThroughDefaults() {
        let defaults = freshDefaults()
        let written = TranscriptionPreferences(defaults: defaults)
        written.provider = .openAI
        written.openAIModel = .gptTranscribe
        written.openAIExpectedLanguages = [.mandarinChinese]
        written.appleSpeechLocaleIdentifier = "en-US"

        let read = TranscriptionPreferences(defaults: defaults)
        #expect(read.openAIModel == .gptTranscribe)
        #expect(read.configuration == TranscriptionConfiguration(
            provider: .openAI,
            openAIModel: .gptTranscribe,
            openAIExpectedLanguages: [.mandarinChinese],
            appleSpeechLocaleIdentifier: "en-US"))
    }

    @Test func unknownSelectionsUseSafeDefaults() {
        let defaults = freshDefaults()
        defaults.set("future-provider", forKey: "transcription.provider")
        defaults.set("future-model", forKey: "transcription.openai.model")
        defaults.set(["future-language"], forKey: "transcription.openai.expected-languages")
        let preferences = TranscriptionPreferences(defaults: defaults)
        #expect(preferences.provider == .openAI)
        #expect(preferences.openAIModel == .gpt4oTranscribe)
        #expect(preferences.openAIExpectedLanguages.isEmpty)
    }

    /// Releases 0.1.2-0.1.5 wrote only this key, so dropping it would silently reset a real user's
    /// language choice to Automatic.
    @Test func releasedLanguageProfilesStillResolve() {
        let legacyProfiles: [(String, [OpenAITranscriptionLanguage])] = [
            ("automatic", []),
            ("english", [.english]),
            ("mandarin-chinese", [.mandarinChinese]),
            ("english-and-mandarin-chinese", [.english, .mandarinChinese]),
        ]

        for (rawValue, expected) in legacyProfiles {
            let defaults = freshDefaults()
            defaults.set(rawValue, forKey: "transcription.openai.language-profile")
            #expect(TranscriptionPreferences(defaults: defaults).openAIExpectedLanguages == expected)
        }
    }

    @Test func savingExpectedLanguagesReplacesTheLegacyProfile() {
        let defaults = freshDefaults()
        defaults.set("english", forKey: "transcription.openai.language-profile")
        let preferences = TranscriptionPreferences(defaults: defaults)

        preferences.openAIExpectedLanguages = [.mandarinChinese]

        #expect(preferences.openAIExpectedLanguages == [.mandarinChinese])
        #expect(defaults.object(forKey: "transcription.openai.language-profile") == nil)
    }

    /// An explicitly emptied list is Automatic and must not fall back through the legacy key.
    @Test func anEmptySavedListWinsOverALegacyProfile() {
        let defaults = freshDefaults()
        defaults.set("english", forKey: "transcription.openai.language-profile")
        TranscriptionPreferences(defaults: defaults).openAIExpectedLanguages = []
        #expect(TranscriptionPreferences(defaults: defaults).openAIExpectedLanguages.isEmpty)
    }

    @Test func displayNamesAndCredentialRequirementsAreStable() {
        #expect(TranscriptionProvider.openAI.displayName == "OpenAI")
        #expect(TranscriptionProvider.openAI.requiresOpenAIAPIKey)
        #expect(TranscriptionProvider.appleSpeech.displayName == "Apple Speech")
        #expect(!TranscriptionProvider.appleSpeech.requiresOpenAIAPIKey)
        #expect(OpenAITranscriptionModel.gpt4oTranscribe.displayName
                == "GPT-4o Transcribe")
        #expect(OpenAITranscriptionModel.gptTranscribe.displayName
                == "GPT Transcribe")
        #expect(OpenAITranscriptionModel.gptLiveTranscribe.displayName
                == "GPT Live Transcribe")
        #expect(OpenAITranscriptionLanguage.english.displayName == "English")
        #expect(OpenAITranscriptionLanguage.mandarinChinese.displayName == "Mandarin")
        #expect(OpenAITranscriptionModel.gpt4oTranscribe.turnDetectionStrategy == .serverVAD)
        #expect(OpenAITranscriptionModel.gptTranscribe.turnDetectionStrategy == .clientCommit)
        #expect(OpenAITranscriptionModel.gptLiveTranscribe.turnDetectionStrategy == .clientCommit)
    }

    @Test func turnStrategyAppliesOnlyToOpenAIConfiguration() {
        let openAI = TranscriptionConfiguration(
            provider: .openAI,
            openAIModel: .gptLiveTranscribe,
            openAIExpectedLanguages: [],
            appleSpeechLocaleIdentifier: "en-US")
        let apple = TranscriptionConfiguration(
            provider: .appleSpeech,
            openAIModel: .gptLiveTranscribe,
            openAIExpectedLanguages: [],
            appleSpeechLocaleIdentifier: "en-US")

        #expect(openAI.turnDetectionStrategy == .clientCommit)
        #expect(apple.turnDetectionStrategy == nil)
    }

    @Test func gptTranscribeTurnStrategyAppliesOnlyToOpenAIConfiguration() {
        let openAI = TranscriptionConfiguration(
            provider: .openAI,
            openAIModel: .gptTranscribe,
            openAIExpectedLanguages: [],
            appleSpeechLocaleIdentifier: "en-US")
        let apple = TranscriptionConfiguration(
            provider: .appleSpeech,
            openAIModel: .gptTranscribe,
            openAIExpectedLanguages: [],
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
