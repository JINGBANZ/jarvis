import Foundation

public enum TranscriptionLanguage: String, CaseIterable, Codable, Sendable {
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

    /// Declaration order, duplicates removed.
    public static func canonicalizing(
        _ languages: [TranscriptionLanguage]
    ) -> [TranscriptionLanguage] {
        let selected = Set(languages)
        return allCases.filter(selected.contains)
    }

    /// ISO-639-1, for GPT-4o Transcribe's single `language` hint.
    public var singularHint: String {
        switch self {
        case .english: "en"
        case .mandarinChinese: "zh"
        }
    }

    /// For OpenAI's `languages` list, which accepts regional Chinese codes.
    public var multipleHint: String {
        switch self {
        case .english: "en"
        case .mandarinChinese: "zh-cn"
        }
    }

    /// Google's documented region-qualified codes. The live endpoint accepts any value and treats
    /// it only as a soft bias.
    public var geminiHint: String {
        switch self {
        case .english: "en-US"
        case .mandarinChinese: "cmn-Hans-CN"
        }
    }
}
