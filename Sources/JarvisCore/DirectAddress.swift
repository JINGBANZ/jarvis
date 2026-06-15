import Foundation

/// Detects whether a transcribed utterance is the user addressing Jarvis directly (a wake-word),
/// so the coach can force a reply and bypass the cooldown.
///
/// Deliberately a fast, pure heuristic — NOT a trained wake-word model. It accepts the two natural
/// vocative positions and rejects narration:
///   • LEADING — the name is the first meaningful token, after stripping disfluency fillers
///     ("um", "uh"), optionally introduced by a greeting carrier ("hey/hi/ok …"): "Jarvis, …",
///     "hey there Jarvis …", "um, ok jarvis …".
///   • TRAILING — the utterance ends on the name: "Can you check this, Jarvis?".
/// A name buried after a discourse marker ("So Jarvis told me…", "Well Jarvis was right") is
/// narration, NOT an address, and is rejected — as is a late mention ("…the approach with jarvis
/// earlier…") or a collision like "Travis CI". Common `gpt-4o-transcribe` mis-renders are matched
/// via a small allow-list plus edit-distance ≤ 1 to "jarvis". Runs on every utterance, so it's cheap.
public enum DirectAddress {
    /// Known mis-transcriptions to accept in addition to the edit-distance check. "travis" is
    /// deliberately EXCLUDED — it collides with "Travis CI", common in a coding session.
    private static let extraVariants: Set<String> = ["jervis", "javis", "jarvus", "jarvi", "jarviss"]
    /// Disfluency tokens skipped at the start before looking for the name.
    private static let fillers: Set<String> = ["um", "uh", "uhh", "uhm", "er", "erm", "hmm", "mm"]
    /// Greeting carriers that may precede the name ("hey jarvis", "ok jarvis").
    private static let carriers: Set<String> = ["hey", "hi", "hello", "ok", "okay", "yo", "yeah", "hiya"]

    /// True if `text` looks like a direct address to Jarvis.
    public static func isAddressed(_ text: String) -> Bool {
        let tokens = text.lowercased().split { !$0.isLetter }.map(String.init)
        guard !tokens.isEmpty else { return false }

        // TRAILING vocative: the sentence ends on the name.
        if let last = tokens.last, isNameToken(last) { return true }

        // LEADING address: skip disfluency fillers, then the name must be the first token, or follow
        // a greeting carrier within the next two tokens. Discourse markers (so/well/then) are NOT
        // carriers, so narration like "So Jarvis told me…" is correctly rejected.
        let meaningful = Array(tokens.drop(while: fillers.contains))
        guard let head = meaningful.first else { return false }
        if isNameToken(head) { return true }
        if carriers.contains(head) {
            return meaningful.dropFirst().prefix(2).contains(where: isNameToken)
        }
        return false
    }

    private static func isNameToken(_ token: String) -> Bool {
        token == "jarvis" || extraVariants.contains(token) || editDistance(token, "jarvis") <= 1
    }

    /// Levenshtein distance, short-circuited — inputs here are single words.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
