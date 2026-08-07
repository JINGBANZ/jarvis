import Foundation

/// Decides whether a transcript line carries coaching-relevant substance or is pure back-channel
/// filler ("Hmm", "嗯嗯", "ok"). The coach loop removes known filler from brain-facing context and
/// skips a turn-end whose whole delta is filler — from either speaker — so it never buys a request.
/// The finalized transcript still remains in Activity for the user to audit.
///
/// Why a list is enough: back-channels are a small CLOSED class per language (roughly a dozen forms);
/// the apparent endless variety is elongation/repetition, which the repeat-collapsing normalization
/// absorbs ("Hmmmm." → "hm", "嗯嗯" → "嗯"). Everything outside that closed class FAILS OPEN to
/// the brain — including unknown short fragments. The model stays the judge of meaning; this is
/// punctuation-level hygiene, not a wake-word gate.
public enum TurnSubstance {
    /// A bare rejection from the interviewer is not a back-channel: it corrects the user's current
    /// understanding and needs an immediate coaching turn. The same words from the user remain
    /// filler ("no, no" while thinking aloud), so this override must see the speaker label.
    private static let interviewerCorrections: Set<String> = ["no", "nope"]

    /// Human-readable back-channel forms, kept in natural spelling. Each is run through `normalized`
    /// when the set is built, so entries stay readable while being guaranteed to match normalized
    /// input — an entry with a doubled letter ("cool", "i see") can't silently die to the collapse
    /// step. To add a language, add its dozen closed-class forms in plain spelling.
    private static let fillers: Set<String> = Set([
        // English
        "hm", "m", "mhm", "uh", "um", "uhuh", "uhum", "ok", "okay",
        "yes", "yeah", "yep", "no", "nope", "right", "sure", "wow", "oh", "ah", "so",
        "cool", "got it", "i see", "alright",
        // Chinese
        "嗯", "恩", "啊", "哦", "噢", "呃", "好", "好的", "好吧", "好了",
        "对", "对的", "是", "是的", "明白", "可以", "行", "了解",
    ].map(normalized))

    /// Separators that may join several independent filler acknowledgements in one transcription
    /// result ("Uh. Okay. Hmm."). Whitespace is deliberately excluded because some closed-class
    /// entries are phrases ("got it", "I see"); an unknown phrase continues to fail open.
    private static let fillerSeparators = CharacterSet.punctuationCharacters
        .union(.symbols)
        .union(.newlines)

    /// True when the line should reach the brain. Order matters: overrides first (a question or an
    /// address is always substance, whoever said it), then normalize and consult the closed class.
    public static func isSubstantive(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("jarvis") { return true }
        if lower.contains("?") || lower.contains("？") { return true }

        let collapsed = normalized(lower)

        if collapsed.isEmpty { return false }                       // pure punctuation / noise
        if fillers.contains(collapsed) { return false }             // one known back-channel
        if isKnownFillerSequence(lower) { return false }            // several known back-channels
        return true
    }

    /// Speaker-aware entry point used by the coach's delta gate. Most filler behavior stays neutral,
    /// but a terse interviewer rejection is a correction, not conversational noise.
    public static func isSubstantive(_ line: TranscriptLine) -> Bool {
        if line.speaker == .them, containsInterviewerCorrection(line.text.lowercased()) {
            return true
        }
        return isSubstantive(line.text)
    }

    /// Keep only letters/digits (CJK ideographs are letters), dropping punctuation, whitespace, and
    /// symbols; then collapse consecutive repeats so elongations fold onto their base form
    /// ("Hmmmm." → "hm", "嗯嗯" → "嗯"). Applied to both incoming lines and the `fillers` set so the
    /// two are compared in the same shape.
    private static func normalized(_ lower: String) -> String {
        var collapsed = ""
        for scalar in lower.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            let ch = Character(scalar)
            if collapsed.last != ch { collapsed.append(ch) }
        }
        return collapsed
    }

    /// True only when punctuation/newlines separate two or more known filler forms. Requiring every
    /// part to be in the closed class keeps technical fragments such as "B.F.S." substantive.
    private static func isKnownFillerSequence(_ lower: String) -> Bool {
        let parts = normalizedSeparatorParts(lower)
        return parts.count > 1 && parts.allSatisfy(fillers.contains)
    }

    /// A composite interviewer line such as "No. Okay." still carries an immediate correction even
    /// though each component is otherwise in the filler class.
    private static func containsInterviewerCorrection(_ lower: String) -> Bool {
        normalizedSeparatorParts(lower).contains(where: interviewerCorrections.contains)
    }

    private static func normalizedSeparatorParts(_ lower: String) -> [String] {
        lower.components(separatedBy: fillerSeparators)
            .map(normalized)
            .filter { !$0.isEmpty }
    }
}
