import Foundation

/// One language a user expects speakers to use during a transcription session.
///
/// Expected languages are persisted and transported as a list so adding another supported language
/// never requires defining every possible language combination. An empty list means automatic
/// detection and sends no language hint. `singularHint`/`multipleHint` are OpenAI's contract; Gemini
/// has its own documented codes, see `geminiHint`.
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

    /// Stable declaration order with duplicate selections removed.
    public static func canonicalizing(
        _ languages: [TranscriptionLanguage]
    ) -> [TranscriptionLanguage] {
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

    /// Gemini's own documented `languageCodes` values — distinct from `multipleHint`, which is
    /// OpenAI's contract and stays untouched here since it is shared with that provider's wire
    /// payload. Google documents region-qualified codes (`en-US`/`en-GB`/`en-IN`, `cmn-Hans-CN`)
    /// rather than the bare `en`/`zh-cn` OpenAI accepts.
    ///
    /// NOT a proven bug fix: probing the live Gemini endpoint found `languageCodes` accepts anything
    /// (a nonsense control value was accepted) and behaves as a soft bias rather than a hard
    /// constraint — English audio still transcribed cleanly even with a Mandarin hint. Sending the
    /// documented codes is a no-cost risk reduction, not a fix for an observed failure.
    public var geminiHint: String {
        switch self {
        case .english: "en-US"
        case .mandarinChinese: "cmn-Hans-CN"
        }
    }
}
