import Foundation

/// The one path provider text takes before it can be shown to a person or persisted in Activity.
/// Provider error messages are useful evidence (they name the real cause of failures nobody has
/// classified yet) but can echo credentials: OpenAI's invalid-key message embeds a masked key
/// fragment, and a transport error's description embeds the failing URL, which for Gemini carries
/// the API key as a query parameter. Redaction is pattern-based and conservative: anything shaped
/// like a key, token, or key-bearing query parameter is replaced, everything else is kept.
public enum ProviderMessageRedaction {
    public static let maximumLength = 300

    // `sk-` starts a key only at a word boundary, and "bearer" precedes a token only when something
    // long and token-shaped follows: an unanchored pattern eats ordinary words ("task-force",
    // "disk-image", "the bearer of this message"), and a message with words silently missing is
    // worse evidence than no message at all.
    private static let patterns: [(NSRegularExpression, String)] = [
        (regex(#"(?<![A-Za-z0-9])sk-[A-Za-z0-9_\-*.]{4,}"#), "sk-…"),
        (regex(#"AIza[A-Za-z0-9_\-*]{4,}"#), "AIza…"),
        (regex(#"(?i)bearer\s+[A-Za-z0-9._\-]{8,}"#), "Bearer …"),
        (regex(#"(?i)([?&](?:key|api_key|apikey|token|access_token)=)[^&\s"']+"#), "$1…"),
        (regex(#"(?i)(x-goog-api-key:\s*)[^\s"']+"#), "$1…"),
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
