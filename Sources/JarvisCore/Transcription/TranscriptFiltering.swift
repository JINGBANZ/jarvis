import Foundation

public enum TranscriptFiltering {
    /// Caption artifacts models emit when VAD fires on silence, matched against a whole utterance
    /// only. Add only well-attested phrases. "bye" is deliberately absent: it is a real sign-off.
    static let hallucinationDenylist: Set<String> = [
        "you", "thank you", "thank you very much", "thanks", "thanks for watching",
        "thank you for watching", "please subscribe",
    ]

    /// The denylist applies to `.me` only: a bare "Thanks" is a silence hallucination on the mic
    /// but a real reply from the other side.
    public static func meaningfulTranscript(_ raw: String, speaker: Speaker) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        if speaker == .me {
            // No apostrophe: trimming it could mangle a quoted word.
            let normalized = trimmed.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?…\" "))
            guard !hallucinationDenylist.contains(normalized) else { return nil }
        }
        return trimmed
    }
}
