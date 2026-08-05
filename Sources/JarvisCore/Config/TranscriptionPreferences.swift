import Foundation

/// Persisted transcription choices. Unknown values retain the established provider/model defaults;
/// language expectations default to automatic so Jarvis never silently assumes English.
public final class TranscriptionPreferences {
    private let defaults: UserDefaults

    private enum Key {
        static let provider = "transcription.provider"
        static let openAIModel = "transcription.openai.model"
        static let openAILanguageProfile = "transcription.openai.language-profile"
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

    public var openAILanguageProfile: OpenAITranscriptionLanguageProfile {
        get {
            guard let raw = defaults.string(forKey: Key.openAILanguageProfile),
                  let profile = OpenAITranscriptionLanguageProfile(rawValue: raw) else {
                return .automatic
            }
            return profile
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.openAILanguageProfile)
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
            openAILanguageProfile: openAILanguageProfile,
            appleSpeechLocaleIdentifier: appleSpeechLocaleIdentifier)
    }
}
