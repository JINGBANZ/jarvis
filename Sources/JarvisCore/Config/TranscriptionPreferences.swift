import Foundation

/// Persisted transcription-provider selection. Unknown or absent values fail back to OpenAI so an
/// existing installation keeps the provider it used before this preference existed.
public final class TranscriptionPreferences {
    private let defaults: UserDefaults

    private enum Key {
        static let provider = "transcription.provider"
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
}
