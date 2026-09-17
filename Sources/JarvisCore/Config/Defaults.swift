import Foundation

/// Every user-facing setting's UserDefaults key, default value, and valid range. Harness tunables
/// the user never sees belong in `Config`.
public enum Defaults {

    // MARK: - Brain

    public enum Brain {
        public static let providerKey = "brain.provider"
        /// Matches the transcription default, so a first run needs only one credential.
        public static let provider: BrainProvider = .openAI

        public static let fallbackTargetsKey = "brain.fallbackTargets"
        public static let fallbackTargets: [BrainTarget] = []

        public static let effortKey = "brain.reasoningEffort"
        /// Keeps a coaching turn fast (sub-2s target) while still allowing tool calls.
        public static let effort: ReasoningEffort = .low

        public static let disabledToolsKey = "brain.disabledTools"
        public static let disabledTools: [String] = []

        public static let disabledSkillsKey = "brain.disabledSkills"
        public static let disabledSkills: [String] = []

        /// OpenAI keeps the unsuffixed "brain.model" key so saved selections survive.
        public static func modelKey(for provider: BrainProvider) -> String {
            provider == .openAI ? "brain.model" : "brain.model.\(provider.rawValue)"
        }

        public static func model(for provider: BrainProvider) -> BrainModel {
            BrainModelCatalog.defaultModel(for: provider)
        }
    }

    // MARK: - Transcription

    public enum Transcription {
        public static let providerKey = "transcription.provider"
        public static let provider: TranscriptionProvider = .openAI

        public static let openAIModelKey = "transcription.openai.model"
        public static let openAIModel: OpenAITranscriptionModel = .gpt4oTranscribe

        public static let openAIExpectedLanguagesKey = "transcription.openai.expected-languages"
        /// Empty means automatic detection. Never assume English.
        public static let openAIExpectedLanguages: [TranscriptionLanguage] = []

        public static let openAIVocabularyKeywordsKey = "transcription.openai.vocabulary-keywords"
        public static let openAIVocabularyKeywords: [String] = []

        public static let appleSpeechLocaleKey = "transcription.apple-speech.locale"
        public static var appleSpeechLocaleIdentifier: String { Locale.current.identifier }

        public static let geminiModelKey = "transcription.gemini.model"
        public static let geminiModel: GeminiTranscriptionModel = .geminiTranscribeLive

        public static let geminiExpectedLanguagesKey = "transcription.gemini.expected-languages"
        /// Empty means automatic detection.
        public static let geminiExpectedLanguages: [TranscriptionLanguage] = []

        public static let geminiVocabularyKeywordsKey = "transcription.gemini.vocabulary-keywords"
        public static let geminiVocabularyKeywords: [String] = []

        public static let geminiModeKey = "transcription.gemini.mode"
        /// Verbatim, because coaching reasons about what was actually said.
        public static let geminiMode: GeminiTranscriptionMode = .verbatim
    }

    // MARK: - Screen capture

    public enum Screen {
        public static let scopeKey = "screen.captureScope"
        /// The most private scope, and the only one with text evidence.
        public static let scope: ScreenCaptureScope = .activeWindow

        public static let displayIndexKey = "screen.captureDisplayIndex"
        /// 1-based, as `screencapture -D` counts displays (1 = the menu-bar display).
        public static let displayIndex = 1
        public static let displayIndexMinimum = 1

        public static let browserTextEnabledKey = "screen.browserTextEnabled"
        /// Accessibility is a broad optional grant, so it starts disabled.
        public static let browserTextEnabled = false
    }

    // MARK: - Hotkey

    public enum Hotkey {
        public static let previousDetailKeyCodeKey = "hotkey.previousDetail.keyCode"
        public static let previousDetailModifiersKey = "hotkey.previousDetail.modifiers"
        public static let previousDetailCombination = HotkeyCombination(
            keyCode: 123, modifiers: [.command, .option])
        public static let nextDetailKeyCodeKey = "hotkey.nextDetail.keyCode"
        public static let nextDetailModifiersKey = "hotkey.nextDetail.modifiers"
        public static let nextDetailCombination = HotkeyCombination(
            keyCode: 124, modifiers: [.command, .option])
        public static let codeKeyCodeKey = "hotkey.code.keyCode"
        public static let codeModifiersKey = "hotkey.code.modifiers"
        /// kVK_ANSI_K.
        public static let codeCombination = HotkeyCombination(keyCode: 40, modifiers: [.command, .option])
        public static let explanationKeyCodeKey = "hotkey.explanation.keyCode"
        public static let explanationModifiersKey = "hotkey.explanation.modifiers"
        /// kVK_ANSI_E.
        public static let explanationCombination = HotkeyCombination(
            keyCode: 14, modifiers: [.command, .option])
        public static let keyCodeKey = "hotkey.keyCode"
        public static let modifiersKey = "hotkey.modifiers"

        /// kVK_ANSI_J. Carbon key codes are physical key positions, so no layout handling is
        /// needed.
        public static let keyCode: UInt32 = 38
        public static let modifiers: HotkeyModifiers = [.command, .option]
        public static var combination: HotkeyCombination {
            HotkeyCombination(keyCode: keyCode, modifiers: modifiers)
        }
    }

    // MARK: - Prep material

    public enum PrepMaterial {
        public static let sourcesKey = "prepMaterial.sources"
        public static let sources: [PrepMaterialSource] = []
    }

    // MARK: - Permissions

    /// Never store a permission grant here: a stored grant can't be told apart from a current one,
    /// so grants are checked live.
    public enum Permissions {
        public static let screenRecordingAskedKey = "permissions.screenRecordingAsked"
        public static let screenRecordingAsked = false

    }

    // MARK: - Overlay

    /// Opacity is the background fill only, so 0 is a text-only surface, not a hidden one.
    public enum Overlay {
        /// Keys keep the `overlayCode` spelling so existing saved values still load.
        public enum Detail {
            public static let fontSizeKey = "overlayCode.fontSize"
            public static let fontSize: Double = 18
            public static let fontSizeRange: ClosedRange<Double> = 12...18
            public static let opacityKey = "overlayCode.backgroundOpacity"
            public static let opacity: Double = 1
            public static let opacityRange: ClosedRange<Double> = 0...1
        }


        public enum Caption {
            public static let enabledKey = "overlayCaption.enabled"
            public static let enabled = false

            public static let fontSizeKey = "overlayCaption.fontSize"
            public static let fontSize: Double = 18
            public static let fontSizeRange: ClosedRange<Double> = 12...32

            public static let opacityKey = "overlayCaption.backgroundOpacity"
            public static let opacity: Double = 0.78
            public static let opacityRange: ClosedRange<Double> = 0...1.0
        }

        public enum Box {
            public static let enabledKey = "overlayBox.enabled"
            public static let enabled = true

            public static let fontSizeKey = "overlayBox.fontSize"
            public static let fontSize: Double = 25
            public static let fontSizeRange: ClosedRange<Double> = 12...32

            public static let opacityKey = "overlayBox.opacity"
            public static let opacity: Double = 0.45
            public static let opacityRange: ClosedRange<Double> = 0...1.0

            // Lower bounds are the panel's `minSize`. 4096 pt only rejects a corrupt plist value;
            // it exceeds any display's logical width (a 6K XDR is 3008 pt).
            public static let widthKey = "overlayBox.width"
            public static let width: Double = 520
            public static let widthRange: ClosedRange<Double> = 240...4096

            public static let heightKey = "overlayBox.height"
            public static let height: Double = 440
            public static let heightRange: ClosedRange<Double> = 140...4096
        }
    }
}
