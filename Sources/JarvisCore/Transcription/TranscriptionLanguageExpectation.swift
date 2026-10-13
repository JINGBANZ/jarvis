import Foundation

public enum TranscriptionLanguageExpectation: Codable, Equatable, Sendable {
    case automatic
    case languages([TranscriptionLanguage])
    case locale(String)

    public init(languages: [TranscriptionLanguage]) {
        let languages = TranscriptionLanguage.canonicalizing(languages)
        self = languages.isEmpty ? .automatic : .languages(languages)
    }

    public var languages: [TranscriptionLanguage] {
        if case .languages(let languages) = self {
            return TranscriptionLanguage.canonicalizing(languages)
        }
        return []
    }
}
