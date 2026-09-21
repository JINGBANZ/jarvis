import Testing
@testable import JarvisCore

@Suite struct RobotPartSummariesTests {
    @Test func brainNamesTheModelTheProviderAndTheEffortLevel() {
        let summary = RobotPartSummaries.brain(
            primary: BrainTarget(provider: .codexSubscription, modelID: "gpt-5.5"),
            effort: .high)
        #expect(summary == RobotPartSummary(value: "GPT-5.5", detail: "VIA CODEX", level: 3))
    }

    @Test func noEffortLightsNoBars() {
        let summary = RobotPartSummaries.brain(
            primary: BrainTarget(provider: .openAI, modelID: "gpt-5.5"), effort: .none)
        #expect(summary.level == 0)
        #expect(summary.detail == "VIA OPENAI API")
    }

    @Test func earShortensTheModelAndListsLanguages() {
        let configuration = TranscriptionConfiguration(
            provider: .openAI,
            openAIModel: .gptTranscribe,
            openAIExpectedLanguages: [.mandarinChinese, .english],
            appleSpeechLocaleIdentifier: "en_US")
        #expect(RobotPartSummaries.ear(configuration)
            == RobotPartSummary(value: "OpenAI · GPT", detail: "HEARS EN · 中文"))
    }

    @Test func gpt4oWithTwoLanguagesHearsAnyLanguage() {
        let twoLanguages = TranscriptionConfiguration(
            provider: .openAI,
            openAIModel: .gpt4oTranscribe,
            openAIExpectedLanguages: [.english, .mandarinChinese],
            appleSpeechLocaleIdentifier: "en_US")
        #expect(RobotPartSummaries.ear(twoLanguages)
            == RobotPartSummary(value: "OpenAI · GPT-4o", detail: "HEARS ANY LANGUAGE"))
        let oneLanguage = TranscriptionConfiguration(
            provider: .openAI,
            openAIModel: .gpt4oTranscribe,
            openAIExpectedLanguages: [.english],
            appleSpeechLocaleIdentifier: "en_US")
        #expect(RobotPartSummaries.ear(oneLanguage).detail == "HEARS EN")
    }

    @Test func geminiDoesNotRepeatTheVendor() {
        let configuration = TranscriptionConfiguration(
            provider: .gemini,
            openAIModel: .gpt4oTranscribe,
            openAIExpectedLanguages: [],
            appleSpeechLocaleIdentifier: "en_US")
        #expect(RobotPartSummaries.ear(configuration)
            == RobotPartSummary(value: "Gemini 3.5 Live", detail: "HEARS ANY LANGUAGE"))
    }

    @Test func appleSpeechShowsItsLocale() {
        let configuration = TranscriptionConfiguration(
            provider: .appleSpeech,
            openAIModel: .gpt4oTranscribe,
            openAIExpectedLanguages: [],
            appleSpeechLocaleIdentifier: "zh_CN")
        #expect(RobotPartSummaries.ear(configuration)
            == RobotPartSummary(value: "Apple Speech", detail: "HEARS ZH-CN"))
    }

    @Test func eyeDescribesTheScope() {
        #expect(RobotPartSummaries.eye(scope: .activeWindow, displayIndex: 1, browserTextEnabled: false)
            == RobotPartSummary(value: "Active window", detail: "CHROME TEXT OFF"))
        #expect(RobotPartSummaries.eye(scope: .activeWindow, displayIndex: 1, browserTextEnabled: true)
            .detail == "CHROME TEXT ON")
        #expect(RobotPartSummaries.eye(scope: .entireDisplay, displayIndex: 2, browserTextEnabled: true)
            == RobotPartSummary(value: "Display 2", detail: "WHOLE SCREEN"))
    }

    @Test func mouthNamesTheBoxAndItsTextSize() {
        #expect(RobotPartSummaries.mouth(fontSize: 25)
            == RobotPartSummary(value: "Overlay Box", detail: "25 PT TEXT"))
        #expect(RobotPartSummaries.mouth(fontSize: 18.4).detail == "18 PT TEXT")
    }
}
