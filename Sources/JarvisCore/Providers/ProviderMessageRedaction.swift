import Foundation

/// Provider messages can echo credentials: OpenAI's invalid-key message embeds a key fragment, and
/// a transport error embeds the failing URL, which carries Gemini's API key. Anything key-shaped is
/// replaced; everything else is kept as evidence.
public enum ProviderMessageRedaction {
    public static let maximumLength = 300

    // Anchored so ordinary words ("task-force", "the bearer of this message") survive: a message
    // with words silently missing is worse evidence than none.
    private static let patterns: [(NSRegularExpression, String)] = [
        (regex(#"(?<![A-Za-z0-9])sk-[A-Za-z0-9_\-*.]{4,}"#), "sk-…"),
        (regex(#"AIza[A-Za-z0-9_\-*]{4,}"#), "AIza…"),
        (regex(#"(?i)bearer\s+[A-Za-z0-9._\-]{8,}"#), "Bearer …"),
        (regex(#"(?i)([?&](?:key|api_key|apikey|token|access_token)=)[^&\s"']+"#), "$1…"),
        (regex(#"(?i)(x-goog-api-key:\s*)[^\s"']+"#), "$1…"),
        // For stderr prose like `token=abc` (no `?` or `&`). The long value spares `retries=3`.
        // The lookbehind allows `_`, so `OPENAI_API_KEY=` matches while `mytoken=` does not.
        (regex(#"(?i)(?<![A-Za-z0-9])((?:api[_-]?key|access[_-]?token|auth[_-]?token|token|secret)"?\s*[=:]\s*"?)[A-Za-z0-9._\-+/=]{8,}"#), "$1…"),
        // A JWT is a credential wherever it turns up, and nothing else is shaped like one.
        (regex(#"(?<![A-Za-z0-9])eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}(?:\.[A-Za-z0-9_\-]+)?"#), "eyJ…"),
    ]

    public static func redact(_ text: String) -> String {
        var result = text
        for (pattern, template) in patterns {
            result = pattern.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        let collapsed = result
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maximumLength else { return collapsed }
        return String(collapsed.prefix(maximumLength - 1)) + "…"
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals reviewed with this file; a malformed one is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }
}
