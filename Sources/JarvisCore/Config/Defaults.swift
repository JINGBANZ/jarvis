import Foundation

/// Every user-facing setting's UserDefaults key, default value, and valid range — in one place.
///
/// Adding a setting means editing this file plus the one accessor that exposes it; nothing else in
/// the codebase should spell a preference key or a default value literally. The accessor types
/// (`BrainPreferences`, `TranscriptionPreferences`, `ScreenCapturePreferences`,
/// `OverlayAppearance`) own validation, clamping, and persistence policy, but hold no literals.
///
/// This is deliberately separate from `Config`, which holds runtime tunables the user never sees
/// (silence backoff, VAD windows, overlay reading-time math). If a value appears in the Settings
/// window it belongs here; if it only shapes the harness's own behavior it belongs in `Config`.
public enum Defaults {

    // MARK: - Brain

    /// Which provider/model answers a coaching attempt, and how hard it thinks.
    public enum Brain {
        public static let providerKey = "brain.provider"
        /// The direct OpenAI API. Also the transcription default, so a first run needs one
        /// credential rather than two unrelated setup decisions.
        public static let provider: BrainProvider = .openAI

        public static let fallbackTargetsKey = "brain.fallbackTargets"
        /// No fallbacks until the user adds them; failover is opt-in, never inferred.
        public static let fallbackTargets: [BrainTarget] = []

        public static let effortKey = "brain.reasoningEffort"
        /// Keeps a coaching turn fast (sub-2s target) while still allowing tool calls.
        public static let effort: ReasoningEffort = .low

        /// The OpenAI model keeps the pre-provider key ("brain.model") so existing installs keep
        /// their selection; CLI providers store under a suffixed key each.
        public static func modelKey(for provider: BrainProvider) -> String {
            provider == .openAI ? "brain.model" : "brain.model.\(provider.rawValue)"
        }

        /// Per-provider model defaults are the first entry of that provider's curated list, so they
        /// live with the list itself — see `BrainModelCatalog.defaultModel(for:)`.
        public static func model(for provider: BrainProvider) -> BrainModel {
            BrainModelCatalog.defaultModel(for: provider)
        }
    }

    // MARK: - Transcription

    /// What turns captured audio into the conversation text. Independent of the brain route.
    public enum Transcription {
        public static let providerKey = "transcription.provider"
        public static let provider: TranscriptionProvider = .openAI

        public static let openAIModelKey = "transcription.openai.model"
        public static let openAIModel: OpenAITranscriptionModel = .gpt4oTranscribe

        public static let openAIExpectedLanguagesKey = "transcription.openai.expected-languages"
        /// Empty means automatic detection — Jarvis never silently assumes English.
        public static let openAIExpectedLanguages: [OpenAITranscriptionLanguage] = []

        public static let openAIVocabularyKeywordsKey = "transcription.openai.vocabulary-keywords"
        /// Empty until the user adds terms; only GPT Transcribe and GPT Live send them.
        public static let openAIVocabularyKeywords: [String] = []

        public static let appleSpeechLocaleKey = "transcription.apple-speech.locale"
        /// A visible initial suggestion only; Settings resolves and displays the supported
        /// equivalent so the user can correct it before Start. Computed, not stored, because the
        /// machine's locale is the starting point rather than a fixed value.
        public static var appleSpeechLocaleIdentifier: String { Locale.current.identifier }
    }

    // MARK: - Screen capture

    /// What `capture_screen` shoots when the brain asks for visual context.
    public enum Screen {
        public static let scopeKey = "screen.captureScope"
        /// The frontmost window — the most private option, and the only one with an OCR sidecar.
        public static let scope: ScreenCaptureScope = .activeWindow

        public static let displayIndexKey = "screen.captureDisplayIndex"
        /// 1-based, as `screencapture -D` counts displays (1 = the menu-bar display).
        public static let displayIndex = 1
        public static let displayIndexMinimum = 1
    }

    // MARK: - Hotkey

    /// The one global shortcut: force an immediate hint mid-session.
    public enum Hotkey {
        public static let keyCodeKey = "hotkey.keyCode"
        public static let modifiersKey = "hotkey.modifiers"

        /// kVK_ANSI_J — the original hardcoded binding, so existing installs see no behavior change
        /// until they opt to rebind. Carbon virtual key codes are layout-independent (a fixed
        /// physical key position), so this constant needs no keyboard-layout awareness.
        public static let keyCode: UInt32 = 38
        public static let modifiers: HotkeyModifiers = [.command, .option]
        public static var combination: HotkeyCombination {
            HotkeyCombination(keyCode: keyCode, modifiers: modifiers)
        }
    }

    // MARK: - Prep material

    /// Local files/folders of interview notes the user has pointed Jarvis at, so the coach can draw
    /// on prepared answers. Referenced in place — Jarvis never copies or edits the user's notes.
    public enum PrepMaterial {
        public static let sourcesKey = "prepMaterial.sources"
        /// No material until the user adds it.
        public static let sources: [PrepMaterialSource] = []
    }

    // MARK: - Overlay

    /// The two capture-invisible coaching surfaces. Each has an on/off flag, a font size in points,
    /// and an opacity; the ranges are the clamp bounds applied on every read and write.
    ///
    /// Opacity governs only the background fill, so 0 means a text-only surface with no backdrop,
    /// not a hidden one — the enabled flag is the only thing that hides a surface. Both surfaces
    /// share one range because the Overlay tab presents their sliders identically.
    ///
    /// The surfaces default opposite ways — the caption off, the box on — so a first run shows the
    /// durable history rather than a flashing caption.
    public enum Overlay {

        /// The transient on-screen tip that fades after each response.
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

        /// The persistent, movable history of recent responses.
        public enum Box {
            public static let enabledKey = "overlayBox.enabled"
            public static let enabled = true

            public static let fontSizeKey = "overlayBox.fontSize"
            public static let fontSize: Double = 25
            public static let fontSizeRange: ClosedRange<Double> = 12...32

            /// Dimmed rather than opaque, so the box sits over a busy screen without dominating it.
            public static let opacityKey = "overlayBox.opacity"
            public static let opacity: Double = 0.45
            public static let opacityRange: ClosedRange<Double> = 0...1.0

            // The box is the one surface the user sizes directly, by dragging its edges. The lower
            // bounds are the panel's own `minSize`, so the drag floor and the persisted floor cannot
            // drift apart. The upper bounds only reject a corrupted plist value: 4096 pt clears any
            // display's logical size (a 6K XDR is 3008 pt wide), so it never limits a real drag.
            public static let widthKey = "overlayBox.width"
            public static let width: Double = 520
            public static let widthRange: ClosedRange<Double> = 240...4096

            public static let heightKey = "overlayBox.height"
            public static let height: Double = 440
            public static let heightRange: ClosedRange<Double> = 140...4096
        }
    }
}
