import Foundation

/// Persisted transcription choices. Unknown values retain the established provider/model defaults;
/// language expectations default to automatic so Jarvis never silently assumes English.
public final class TranscriptionPreferences {
    private let defaults: UserDefaults

    private enum Key {
        static let provider = "transcription.provider"
        static let openAIModel = "transcription.openai.model"
        static let openAIExpectedLanguages = "transcription.openai.expected-languages"
        static let appleSpeechLocale = "transcription.apple-speech.locale"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var provider: TranscriptionProvider {
        get {
            guard let raw = defaults.string(forKey: Key.provider),
                  let provider = TranscriptionProvider(rawValue: raw) else {
                return .openAI
            }
            return provider
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.provider)
        }
    }

    public var openAIModel: OpenAITranscriptionModel {
        get {
            guard let raw = defaults.string(forKey: Key.openAIModel),
                  let model = OpenAITranscriptionModel(rawValue: raw) else {
                return .gpt4oTranscribe
            }
            return model
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.openAIModel)
        }
    }

    /// Every language speakers may use. An empty list means automatic detection.
    public var openAIExpectedLanguages: [OpenAITranscriptionLanguage] {
        get {
            let languages = (defaults.stringArray(forKey: Key.openAIExpectedLanguages) ?? [])
                .compactMap(OpenAITranscriptionLanguage.init(rawValue:))
            return OpenAITranscriptionLanguage.canonicalizing(languages)
        }
        set {
            let languages = OpenAITranscriptionLanguage.canonicalizing(newValue)
            defaults.set(languages.map(\.rawValue), forKey: Key.openAIExpectedLanguages)
        }
    }

    /// Apple Speech requires one locale for the complete session. The current macOS locale is a
    /// visible initial suggestion only; Settings resolves and displays the supported equivalent so
    /// the user can correct it before Start.
    public var appleSpeechLocaleIdentifier: String {
        get {
            guard let identifier = defaults.string(forKey: Key.appleSpeechLocale),
                  !identifier.isEmpty else {
                return Locale.current.identifier
            }
            return identifier
        }
        set {
            defaults.set(newValue, forKey: Key.appleSpeechLocale)
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
