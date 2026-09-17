import Foundation

/// Deliberately conservative: short replies such as "Yes", "Okay", or "对" can change the
/// conversation, so only clear hesitation sounds count as filler.
public enum TurnSubstance {
    typealias Classification = CoachingAttemptAuditEvent.Classification

    /// Only non-semantic sounds; keep acknowledgements out even when they are used casually.
    private static let discardableSounds: Set<String> = Set([
        "hm", "m", "uh", "um", "er", "erm", "oh", "ah",
        "嗯", "恩", "啊", "哦", "噢", "呃",
    ].map(normalized))

    /// Hyphen is not a separator, so "Mm-hmm" stays substantive rather than "m" plus "hm".
    private static let soundSeparators = CharacterSet.punctuationCharacters
        .subtracting(CharacterSet(charactersIn: "-"))
        .union(.symbols)
        .union(.whitespacesAndNewlines)

    public static func isSubstantive(_ text: String) -> Bool {
        classification(of: text).isSubstantive
    }

    static func classification(of text: String) -> Classification {
        let lower = text.lowercased()
        if lower.contains("jarvis") { return .substantive }
        if lower.contains("?") || lower.contains("？") { return .substantive }
        if containsAcronymLikeSound(text) { return .substantive }

        let collapsed = normalized(lower)

        if collapsed.isEmpty { return .empty }
        if discardableSounds.contains(collapsed) { return .knownFiller }
        if isDiscardableSoundSequence(lower) { return .compositeFiller }
        return .substantive
    }

    public static func isSubstantive(_ line: TranscriptLine) -> Bool {
        return isSubstantive(line.text)
    }

    /// Alphanumerics only, with repeats collapsed: "Hmmmm." becomes "hm", "嗯嗯" becomes "嗯".
    private static func normalized(_ lower: String) -> String {
        var collapsed = ""
        for scalar in lower.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            let ch = Character(scalar)
            if collapsed.last != ch { collapsed.append(ch) }
        }
        return collapsed
    }

    private static func isDiscardableSoundSequence(_ lower: String) -> Bool {
        let parts = normalizedSeparatorParts(lower)
        return parts.count > 1 && parts.allSatisfy(discardableSounds.contains)
    }

    /// All-caps "ER" or "UM" may be an acronym or variable, while "Um" stays filler.
    private static func containsAcronymLikeSound(_ text: String) -> Bool {
        text.components(separatedBy: soundSeparators).contains { part in
            guard discardableSounds.contains(normalized(part.lowercased())) else { return false }
            let casedLetters = part.unicodeScalars.filter {
                CharacterSet.uppercaseLetters.contains($0) || CharacterSet.lowercaseLetters.contains($0)
            }
            return !casedLetters.isEmpty && casedLetters.allSatisfy {
                CharacterSet.uppercaseLetters.contains($0)
            }
        }
    }

    private static func normalizedSeparatorParts(_ lower: String) -> [String] {
        lower.components(separatedBy: soundSeparators)
            .map(normalized)
            .filter { !$0.isEmpty }
    }
}
