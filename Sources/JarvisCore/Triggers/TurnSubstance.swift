import Foundation

/// Decides whether a transcript line carries coaching-relevant substance or is pure back-channel
/// filler ("Hmm", "嗯嗯", "ok"). The coach loop skips a turn-end whose whole delta is filler — from
/// either speaker — so filler never buys a brain request; the lines still ride along as context on
/// the next substantive turn, and silence checks fire regardless, so a wrong skip costs one turn of
/// delay at most.
///
/// Why a list is enough: back-channels are a small CLOSED class per language (roughly a dozen forms);
/// the apparent endless variety is elongation/repetition, which the repeat-collapsing normalization
/// absorbs ("Hmmmm." → "hm", "嗯嗯" → "嗯"). Unknown-language back-channels are caught by the
/// short-fragment fallback. Everything else FAILS OPEN to the brain — the model stays the judge of
/// meaning; this is punctuation-level hygiene, not a wake-word gate.
public enum TurnSubstance {
    /// Human-readable back-channel forms, kept in natural spelling. Each is run through `normalize`
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
    ].map(normalize))

    /// Keep only letters/digits (CJK ideographs are letters), dropping punctuation, whitespace, and
    /// symbols; then collapse consecutive repeats so elongations fold onto their base form
    /// ("Hmmmm." → "hm", "嗯嗯" → "嗯"). Applied to both incoming lines and the `fillers` set so the
    /// two are compared in the same shape.
    private static func normalize(_ text: String) -> String {
        var collapsed = ""
        for scalar in text.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            let ch = Character(scalar)
            if collapsed.last != ch { collapsed.append(ch) }
        }
        return collapsed
    }

    /// True when the line should reach the brain. Order matters: overrides first (a question or an
    /// address is always substance, whoever said it), then normalize, then the closed-class list and
    /// the ≤2-character fallback.
    public static func isSubstantive(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("jarvis") { return true }
        if lower.contains("?") || lower.contains("？") { return true }

        let collapsed = normalize(lower)

        if collapsed.isEmpty { return false }              // pure punctuation / noise
        if fillers.contains(collapsed) { return false }    // closed-class back-channel
        if collapsed.count <= 2 { return false }           // short fragment in ANY language
        return true
    }
}
