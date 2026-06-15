import Foundation

/// Detects whether a transcribed utterance is the user addressing Jarvis directly (a wake-word),
/// so the coach can force a reply and bypass the cooldown.
///
/// Deliberately a fast, pure heuristic — NOT a trained wake-word model. Two guards keep false
/// positives down: (1) the name must appear near the START of the utterance, so talking *about*
/// Jarvis mid-sentence ("…the approach with jarvis earlier…") or a collision like "Travis CI" later
/// in a sentence won't trigger; (2) common `gpt-4o-transcribe` mis-renders of the proper noun are
/// matched via a small allow-list plus edit-distance ≤ 1 to "jarvis". This runs on every completed
/// utterance, so it must be cheap. A naive anywhere-substring match was rejected in review.
public enum DirectAddress {
    /// Known mis-transcriptions to accept in addition to the edit-distance check. "travis" is
    /// deliberately EXCLUDED — it collides with "Travis CI", common in a coding session.
    private static let extraVariants: Set<String> = ["jervis", "javis", "jarvus", "jarvi", "jarviss"]

    /// True if `text` looks like a direct address to Jarvis.
    public static func isAddressed(_ text: String) -> Bool {
        let tokens = text.lowercased().split { !$0.isLetter }.map(String.init)
        // Anchor to the start: "jarvis …", "hey jarvis …", "ok jarvis …".
        return tokens.prefix(3).contains(where: isNameToken)
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
