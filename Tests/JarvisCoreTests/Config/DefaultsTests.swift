import Testing
@testable import JarvisCore

/// The registry is the single source for every user-facing setting's key, default, and range, so
/// these tests pin the literals a user would see on a fresh install and the invariants the accessor
/// types rely on.
@Suite struct DefaultsTests {

    // MARK: - Keys

    /// Keys are the on-disk contract: renaming one silently discards a real user's saved choice.
    @Test func persistedKeysAreStable() {
        #expect(Defaults.Brain.providerKey == "brain.provider")
        #expect(Defaults.Brain.fallbackTargetsKey == "brain.fallbackTargets")
        #expect(Defaults.Brain.effortKey == "brain.reasoningEffort")
        #expect(Defaults.Brain.interviewFormatKey == "brain.interviewFormat")
        #expect(Defaults.Transcription.providerKey == "transcription.provider")
        #expect(Defaults.Transcription.openAIModelKey == "transcription.openai.model")
        #expect(Defaults.Transcription.openAIExpectedLanguagesKey
            == "transcription.openai.expected-languages")
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
    }

    /// OpenAI keeps the pre-provider key so existing installs keep their model selection.
    @Test func brainModelKeysAreProviderScoped() {
        #expect(Defaults.Brain.modelKey(for: .openAI) == "brain.model")
        #expect(Defaults.Brain.modelKey(for: .claudeCode) == "brain.model.claude-code")
        #expect(Defaults.Brain.modelKey(for: .codexCLI) == "brain.model.codex-cli")
    }

    // MARK: - Values

    @Test func brainDefaults() {
        #expect(Defaults.Brain.provider == .openAI)
        #expect(Defaults.Brain.fallbackTargets.isEmpty)
        #expect(Defaults.Brain.effort == .low)
    }

    /// Every provider's default model must be one its own catalog actually offers.
    @Test func brainModelDefaultsComeFromEachProviderCatalog() {
        for provider in BrainProvider.allCases {
            let model = Defaults.Brain.model(for: provider)
            #expect(BrainModelCatalog.models(for: provider).contains(model))
        }
    }

    @Test func transcriptionDefaults() {
        #expect(Defaults.Transcription.provider == .openAI)
        #expect(Defaults.Transcription.openAIModel == .gpt4oTranscribe)
        // Empty means automatic detection — never a silent assumption of English.
        #expect(Defaults.Transcription.openAIExpectedLanguages.isEmpty)
        #expect(!Defaults.Transcription.appleSpeechLocaleIdentifier.isEmpty)
    }

    @Test func screenDefaults() {
        #expect(Defaults.Screen.scope == .activeWindow)
        #expect(Defaults.Screen.displayIndex == 1)
        #expect(Defaults.Screen.displayIndexMinimum == 1)
    }

    /// kVK_ANSI_J + ⌘⌥ — the original hardcoded ⌥⌘J, so an existing install sees no behavior change
    /// until it opts to rebind.
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
        // Both surfaces expose one opacity range, because the Overlay tab presents them alike.
        #expect(Defaults.Overlay.Box.opacityRange == Defaults.Overlay.Caption.opacityRange)
        #expect(Defaults.Overlay.Box.width == 520)
        #expect(Defaults.Overlay.Box.height == 440)
        // The two surfaces default opposite ways: caption off, box on.
        #expect(Defaults.Overlay.Caption.enabled == false)
        #expect(Defaults.Overlay.Box.enabled == true)
    }

    // MARK: - Invariants

    /// Independent of the exact literals above: every default must sit inside its own range, and
    /// every range must be non-empty. `OverlayAppearance` clamps against these on each read.
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

    /// The display index is 1-based the way `screencapture -D` counts, so the default must not sit
    /// below the clamp floor.
    @Test func screenDisplayIndexDefaultRespectsItsFloor() {
        #expect(Defaults.Screen.displayIndex >= Defaults.Screen.displayIndexMinimum)
    }
}
