import Foundation

/// Session-scoped language selection. Detection belongs to the provider or the app's OS adapter;
/// Core only decides whether the reported language is admitted.
public struct ConversationLanguagePolicy: Sendable, Equatable {
    public let languageCodes: [String]
    public let displayNames: String

    public init(expectedLanguages: [OpenAITranscriptionLanguage] = []) {
        let languages = expectedLanguages.isEmpty
            ? OpenAITranscriptionLanguage.allCases
            : OpenAITranscriptionLanguage.canonicalizing(expectedLanguages)
        languageCodes = languages.map(\.singularHint)
        displayNames = languages.map(\.displayName).joined(separator: ", ")
    }

    /// Apple Speech exposes its own supported locales, independent of the OpenAI picker.
    public init(localeIdentifier: String) {
        let code = Self.baseLanguage(localeIdentifier)
        languageCodes = [code]
        displayNames = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    public func allows(languageCode: String) -> Bool {
        languageCodes.contains(Self.baseLanguage(languageCode))
    }

    /// Missing metadata defers to the app's text detector. A known disallowed language rejects
    /// the whole item, including its streamed fallback; it must never be translated into admission.
    public func allows(detectedLanguageCodes: [String]?) -> Bool {
        (detectedLanguageCodes ?? []).allSatisfy { allows(languageCode: $0) }
    }

    private static func baseLanguage(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map(String.init) ?? ""
    }
}
