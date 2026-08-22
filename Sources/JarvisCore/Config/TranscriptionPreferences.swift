import Foundation

/// Persisted transcription choices; every key and default comes from `Defaults.Transcription`,
/// including the released language-profile key still read for installs that never re-edited it.
/// Unknown values retain the established provider/model defaults; language expectations default to
/// automatic so Jarvis never silently assumes English.
public final class TranscriptionPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var provider: TranscriptionProvider {
        get {
            guard let raw = defaults.string(forKey: Defaults.Transcription.providerKey),
                  let provider = TranscriptionProvider(rawValue: raw) else {
                return Defaults.Transcription.provider
            }
            return provider
        }
        set {
            defaults.set(newValue.rawValue, forKey: Defaults.Transcription.providerKey)
        }
    }

    public var openAIModel: OpenAITranscriptionModel {
        get {
            guard let raw = defaults.string(forKey: Defaults.Transcription.openAIModelKey),
                  let model = OpenAITranscriptionModel(rawValue: raw) else {
                return Defaults.Transcription.openAIModel
            }
            return model
        }
        set {
            defaults.set(newValue.rawValue, forKey: Defaults.Transcription.openAIModelKey)
        }
    }

    /// Every language speakers may use. An empty list means automatic detection.
    public var openAIExpectedLanguages: [OpenAITranscriptionLanguage] {
        get {
            guard let stored = defaults.stringArray(
                forKey: Defaults.Transcription.openAIExpectedLanguagesKey) else {
                return Self.languagesFromLegacyProfile(
                    defaults.string(forKey: Defaults.Transcription.legacyOpenAILanguageProfileKey))
            }
            return OpenAITranscriptionLanguage.canonicalizing(
                stored.compactMap(OpenAITranscriptionLanguage.init(rawValue:)))
        }
        set {
            let languages = OpenAITranscriptionLanguage.canonicalizing(newValue)
            defaults.set(
                languages.map(\.rawValue),
                forKey: Defaults.Transcription.openAIExpectedLanguagesKey)
            defaults.removeObject(
                forKey: Defaults.Transcription.legacyOpenAILanguageProfileKey)
        }
    }

    /// Apple Speech requires one locale for the complete session. The current macOS locale is a
    /// visible initial suggestion only; Settings resolves and displays the supported equivalent so
    /// the user can correct it before Start.
    public var appleSpeechLocaleIdentifier: String {
        get {
            guard let identifier = defaults.string(
                forKey: Defaults.Transcription.appleSpeechLocaleKey),
                  !identifier.isEmpty else {
                return Defaults.Transcription.appleSpeechLocaleIdentifier
            }
            return identifier
        }
        set {
            defaults.set(newValue, forKey: Defaults.Transcription.appleSpeechLocaleKey)
        }
    }

    /// Releases 0.1.2-0.1.5 persisted one of four fixed combination values. Read those until the
    /// user next edits the list, which replaces them with the scalable representation.
    private static func languagesFromLegacyProfile(
        _ rawValue: String?
    ) -> [OpenAITranscriptionLanguage] {
        switch rawValue {
        case "english":
            [.english]
        case "mandarin-chinese":
            [.mandarinChinese]
        case "english-and-mandarin-chinese":
            [.english, .mandarinChinese]
        default:
            Defaults.Transcription.openAIExpectedLanguages
        }
    }

    /// One atomic value for Start-time snapshotting and stale-preparation detection.
    public var configuration: TranscriptionConfiguration {
        TranscriptionConfiguration(
            provider: provider,
            openAIModel: openAIModel,
            openAIExpectedLanguages: openAIExpectedLanguages,
            appleSpeechLocaleIdentifier: appleSpeechLocaleIdentifier)
    }
}
