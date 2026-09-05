import Foundation

/// Persisted transcription choices; every key and default comes from `Defaults.Transcription`.
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
                return Defaults.Transcription.openAIExpectedLanguages
            }
            return OpenAITranscriptionLanguage.canonicalizing(
                stored.compactMap(OpenAITranscriptionLanguage.init(rawValue:)))
        }
        set {
            let languages = OpenAITranscriptionLanguage.canonicalizing(newValue)
            defaults.set(
                languages.map(\.rawValue),
                forKey: Defaults.Transcription.openAIExpectedLanguagesKey)
        }
    }

    /// Literal terms (jargon, names) that bias GPT Transcribe / GPT Live recognition. GPT-4o Transcribe
    /// does not accept them, so they are inert until the user also picks one of those models.
    public var openAIVocabularyKeywords: [String] {
        get {
            guard let stored = defaults.stringArray(
                forKey: Defaults.Transcription.openAIVocabularyKeywordsKey) else {
                return Defaults.Transcription.openAIVocabularyKeywords
            }
            return stored
        }
        set {
            let keywords = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            defaults.set(keywords, forKey: Defaults.Transcription.openAIVocabularyKeywordsKey)
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

    /// One atomic value for Start-time snapshotting and stale-preparation detection.
    public var configuration: TranscriptionConfiguration {
        TranscriptionConfiguration(
            provider: provider,
            openAIModel: openAIModel,
            openAIExpectedLanguages: openAIExpectedLanguages,
            openAIVocabularyKeywords: openAIVocabularyKeywords,
            appleSpeechLocaleIdentifier: appleSpeechLocaleIdentifier)
    }
}
