import Testing
@testable import JarvisCore

@Suite struct DefaultsTests {

    // MARK: - Keys

    /// Renaming a persisted key silently discards a user's saved choice.
    @Test func persistedKeysAreStable() {
        #expect(Defaults.Brain.providerKey == "brain.provider")
        #expect(Defaults.Brain.fallbackTargetsKey == "brain.fallbackTargets")
        #expect(Defaults.Brain.effortKey == "brain.reasoningEffort")
        #expect(Defaults.Brain.disabledToolsKey == "brain.disabledTools")
        #expect(Defaults.Brain.disabledSkillsKey == "brain.disabledSkills")
        #expect(Defaults.Transcription.providerKey == "transcription.provider")
        #expect(Defaults.Transcription.openAIModelKey == "transcription.openai.model")
        #expect(Defaults.Transcription.openAIExpectedLanguagesKey
            == "transcription.openai.expected-languages")
        #expect(Defaults.Transcription.openAIVocabularyKeywordsKey
            == "transcription.openai.vocabulary-keywords")
        #expect(Defaults.Transcription.appleSpeechLocaleKey == "transcription.apple-speech.locale")
        #expect(Defaults.Screen.scopeKey == "screen.captureScope")
        #expect(Defaults.Screen.displayIndexKey == "screen.captureDisplayIndex")
        #expect(Defaults.Overlay.Caption.enabledKey == "overlayCaption.enabled")
        #expect(Defaults.Overlay.Caption.fontSizeKey == "overlayCaption.fontSize")
        #expect(Defaults.Overlay.Caption.opacityKey == "overlayCaption.backgroundOpacity")
        #expect(Defaults.Overlay.Box.enabledKey == "overlayBox.enabled")
        #expect(Defaults.Overlay.Box.fontSizeKey == "overlayBox.fontSize")
        #expect(Defaults.Overlay.Box.opacityKey == "overlayBox.opacity")
        #expect(Defaults.Overlay.Box.widthKey == "overlayBox.width")
        #expect(Defaults.Overlay.Box.heightKey == "overlayBox.height")
        #expect(Defaults.Hotkey.keyCodeKey == "hotkey.keyCode")
        #expect(Defaults.Hotkey.modifiersKey == "hotkey.modifiers")
        #expect(Defaults.Onboarding.completedKey == "onboarding.completed")
    }

    /// OpenAI keeps the unscoped key so existing installs keep their model selection.
    @Test func brainModelKeysAreProviderScoped() {
        #expect(Defaults.Brain.modelKey(for: .openAI) == "brain.model")
        #expect(Defaults.Brain.modelKey(for: .claudeSubscription) == "brain.model.claude-subscription")
        #expect(Defaults.Brain.modelKey(for: .codexSubscription) == "brain.model.codex-subscription")
    }

    // MARK: - Values

    @Test func brainDefaults() {
        #expect(Defaults.Brain.provider == .openAI)
        #expect(Defaults.Brain.fallbackTargets.isEmpty)
        #expect(Defaults.Brain.effort == .low)
    }

    @Test func brainModelDefaultsComeFromEachProviderCatalog() {
        for provider in BrainProvider.allCases {
            let model = Defaults.Brain.model(for: provider)
            #expect(BrainModelCatalog.models(for: provider).contains(model))
        }
    }

    @Test func transcriptionDefaults() {
        #expect(Defaults.Transcription.provider == .openAI)
        #expect(Defaults.Transcription.openAIModel == .gpt4oTranscribe)
        #expect(Defaults.Transcription.openAIExpectedLanguages.isEmpty)
        #expect(Defaults.Transcription.openAIVocabularyKeywords.isEmpty)
        #expect(!Defaults.Transcription.appleSpeechLocaleIdentifier.isEmpty)
    }

    @Test func screenDefaults() {
        #expect(Defaults.Screen.scope == .activeWindow)
        #expect(Defaults.Screen.displayIndex == 1)
        #expect(Defaults.Screen.displayIndexMinimum == 1)
    }

    /// 38 is kVK_ANSI_J, so the default is ⌥⌘J.
    @Test func hotkeyDefaults() {
        #expect(Defaults.Hotkey.keyCode == 38)
        #expect(Defaults.Hotkey.modifiers == [.command, .option])
        #expect(Defaults.Hotkey.combination
            == HotkeyCombination(keyCode: 38, modifiers: [.command, .option]))
    }

    @Test func overlayDefaults() {
        #expect(Defaults.Overlay.Caption.fontSize == 18)
        #expect(Defaults.Overlay.Caption.fontSizeRange == 12...32)
        #expect(Defaults.Overlay.Caption.opacity == 0.78)
        #expect(Defaults.Overlay.Caption.opacityRange == 0...1.0)
        #expect(Defaults.Overlay.Box.fontSize == 25)
        #expect(Defaults.Overlay.Box.opacity == 0.45)
        #expect(Defaults.Overlay.Box.opacityRange == 0...1.0)
        #expect(Defaults.Overlay.Box.opacityRange == Defaults.Overlay.Caption.opacityRange)
        #expect(Defaults.Overlay.Box.width == 520)
        #expect(Defaults.Overlay.Box.height == 440)
        #expect(Defaults.Overlay.Caption.enabled == false)
        #expect(Defaults.Overlay.Box.enabled == true)
    }

    // MARK: - Invariants

    @Test func overlayRangesContainTheirDefaults() {
        let pairs: [(ClosedRange<Double>, Double)] = [
            (Defaults.Overlay.Caption.fontSizeRange, Defaults.Overlay.Caption.fontSize),
            (Defaults.Overlay.Caption.opacityRange, Defaults.Overlay.Caption.opacity),
            (Defaults.Overlay.Box.fontSizeRange, Defaults.Overlay.Box.fontSize),
            (Defaults.Overlay.Box.opacityRange, Defaults.Overlay.Box.opacity),
            (Defaults.Overlay.Box.widthRange, Defaults.Overlay.Box.width),
            (Defaults.Overlay.Box.heightRange, Defaults.Overlay.Box.height),
        ]
        for (range, value) in pairs {
            #expect(range.contains(value))
            #expect(range.lowerBound < range.upperBound)
        }
    }

    /// Display indexes are 1-based, as `screencapture -D` counts.
    @Test func screenDisplayIndexDefaultRespectsItsFloor() {
        #expect(Defaults.Screen.displayIndex >= Defaults.Screen.displayIndexMinimum)
    }
}
