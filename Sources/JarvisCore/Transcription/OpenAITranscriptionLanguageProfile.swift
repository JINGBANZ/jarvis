import Foundation

/// User-supplied expectations for the languages spoken during one OpenAI transcription session.
///
/// This is a hint, not a per-turn language choice: either speaker can use any expected language,
/// including switching languages within one sentence. Automatic mode sends no language field.
public enum OpenAITranscriptionLanguageProfile: String, CaseIterable, Codable, Sendable {
    case automatic
    case english
    case mandarinChinese = "mandarin-chinese"
    case englishAndMandarinChinese = "english-and-mandarin-chinese"

    public var displayName: String {
        switch self {
        case .automatic:
            "Automatic"
        case .english:
            "English"
        case .mandarinChinese:
            "Mandarin Chinese"
        case .englishAndMandarinChinese:
            "English + Mandarin Chinese"
        }
    }

    /// Older transcription models accept at most one ISO-639-1 `language` hint.
    public var singularLanguageHint: String? {
        switch self {
        case .automatic, .englishAndMandarinChinese:
            nil
        case .english:
            "en"
        case .mandarinChinese:
            "zh"
        }
    }

    /// The newest OpenAI transcription models accept a `languages` array, including the documented
    /// regional Chinese codes.
    public var multipleLanguageHints: [String]? {
        switch self {
        case .automatic:
            nil
        case .english:
            ["en"]
        case .mandarinChinese:
            ["zh-cn"]
        case .englishAndMandarinChinese:
            ["en", "zh-cn"]
        }
    }
}
