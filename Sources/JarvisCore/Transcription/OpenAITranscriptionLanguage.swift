import Foundation

/// One language a user expects speakers to use during an OpenAI transcription session.
///
/// Expected languages are persisted and transported as a list so adding another supported language
/// never requires defining every possible language combination. An empty list means automatic
/// detection and sends no language hint to OpenAI.
public enum OpenAITranscriptionLanguage: String, CaseIterable, Codable, Sendable {
    case english
    case mandarinChinese = "mandarin-chinese"

    public var displayName: String {
        switch self {
        case .english:
            "English"
        case .mandarinChinese:
            "Mandarin"
        }
    }

    /// Stable declaration order with duplicate selections removed.
    public static func canonicalizing(
        _ languages: [OpenAITranscriptionLanguage]
    ) -> [OpenAITranscriptionLanguage] {
        let selected = Set(languages)
        return allCases.filter(selected.contains)
    }

    /// Older GPT-4o transcription models accept one ISO-639-1 `language` hint.
    public var singularHint: String {
        switch self {
        case .english: "en"
        case .mandarinChinese: "zh"
        }
    }

    /// Newer transcription models accept a `languages` list, including regional Chinese codes.
    public var multipleHint: String {
        switch self {
        case .english: "en"
        case .mandarinChinese: "zh-cn"
        }
    }
}
