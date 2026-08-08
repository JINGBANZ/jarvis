import Foundation

/// Decides whether a transcript line carries coaching-relevant substance or is only a clear
/// hesitation sound ("Hmm", "Uh", "嗯嗯"). The coach loop removes those sounds from brain-facing
/// context and skips a turn-end whose whole delta is discardable — from either speaker — so it never
/// buys a request.
/// The finalized transcript still remains in Activity for the user to audit.
///
/// The list is deliberately conservative: lexical replies such as "Yes", "No", "Okay", "Right",
/// "对", and "可以" can change the conversation, so they always fail open to the brain regardless of
/// speaker. Elongation/repetition normalization absorbs spelling variants ("Hmmmm." → "hm", "嗯嗯" →
/// "嗯"). The model stays the judge of meaning; this is punctuation-level hygiene, not a wake-word gate.
public enum TurnSubstance {
    /// Human-readable non-semantic vocal sounds, kept in natural spelling. Each is run through
    /// `normalized` when the set is built so it matches normalized input. Keep semantic
    /// acknowledgements out of this set even when they are often used casually.
    private static let discardableSounds: Set<String> = Set([
        // English
        "hm", "m", "uh", "um", "er", "erm", "oh", "ah",
        // Chinese
        "嗯", "恩", "啊", "哦", "噢", "呃",
    ].map(normalized))

    /// Separators that may join several independent hesitation sounds in one transcription result
    /// ("Uh. Hmm. Oh."). Hyphens stay inside a form so affirmative sounds such as "Mm-hmm" fail
    /// open instead of being mistaken for the separate noises "m" and "hm".
    private static let soundSeparators = CharacterSet.punctuationCharacters
        .subtracting(CharacterSet(charactersIn: "-"))
        .union(.symbols)
        .union(.whitespacesAndNewlines)

    /// True when the line should reach the brain. Order matters: overrides first (a question or an
    /// address is always substance, whoever said it), then normalize and consult the closed class.
    public static func isSubstantive(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("jarvis") { return true }
        if lower.contains("?") || lower.contains("？") { return true }
        if containsAcronymLikeSound(text) { return true }

        let collapsed = normalized(lower)

        if collapsed.isEmpty { return false }                              // pure punctuation / noise
        if discardableSounds.contains(collapsed) { return false }          // one clear sound
        if isDiscardableSoundSequence(lower) { return false }              // several clear sounds
        return true
    }

    /// Speaker-labeled entry point used by the coach's delta gate. Classification stays neutral:
    /// ambiguous short replies are preserved for both speakers.
    public static func isSubstantive(_ line: TranscriptLine) -> Bool {
        return isSubstantive(line.text)
    }

    /// Keep only letters/digits (CJK ideographs are letters), dropping punctuation, whitespace, and
    /// symbols; then collapse consecutive repeats so elongations fold onto their base form
    /// ("Hmmmm." → "hm", "嗯嗯" → "嗯"). Applied to both incoming lines and `discardableSounds`
    /// so the two are compared in the same shape.
    private static func normalized(_ lower: String) -> String {
        var collapsed = ""
        for scalar in lower.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            let ch = Character(scalar)
            if collapsed.last != ch { collapsed.append(ch) }
        }
        return collapsed
    }

    /// True only when separators divide two or more clear hesitation sounds. Requiring every part
    /// to be in the conservative set keeps technical fragments such as "B.F.S." substantive.
    private static func isDiscardableSoundSequence(_ lower: String) -> Bool {
        let parts = normalizedSeparatorParts(lower)
        return parts.count > 1 && parts.allSatisfy(discardableSounds.contains)
    }

    /// Preserve an all-uppercase token whose lowercase spelling collides with a sound ("M", "ER",
    /// "UM", "OH"). Capitalization is the only local evidence that it may be a variable or acronym;
    /// ordinary ASR fillers such as "Um" and "Oh" remain discardable.
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
