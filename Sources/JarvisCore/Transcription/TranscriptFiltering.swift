import Foundation

/// Drops non-speech that a transcription model invents — the "`.`-on-silence" problem. Provider-
/// independent: every streaming recognizer emits these artifacts, so the filter lives beside the
/// transcript rather than inside one provider's wire contract.
public enum TranscriptFiltering {
    /// Stock non-speech hallucinations transcription models emit when VAD fires on silence — mostly
    /// YouTube-caption artifacts absorbed in training. Lower-cased, punctuation stripped; matched only
    /// against a whole utterance (see `meaningfulTranscript`) so a real sentence containing these words
    /// survives. Conservative on purpose — add only well-attested phrases here. Applied to the `.me`
    /// side only. "bye" is deliberately absent: it is a well-formed sign-off, and the punctuation
    /// filter already catches the lone-"." artifact.
    static let hallucinationDenylist: Set<String> = [
        "you", "thank you", "thank you very much", "thanks", "thanks for watching",
        "thank you for watching", "please subscribe",
    ]

    /// Returns the utterance trimmed if it is real speech, else nil. Drops two kinds of non-speech:
    ///   1. punctuation/whitespace-only output (a lone "." has no letter or digit) — both speakers, and
    ///   2. an utterance that, normalized, is exactly a known caption-artifact phrase — `.me` only.
    ///
    /// `speaker` scopes the phrase denylist: a bare "Thank you."/"Thanks" is a silence hallucination on
    /// the *me* (mic) side but a real turn-ending reply on the *them* (system-audio) side.
    /// Letting either through logs a phantom `heard` line, resets the silence timer, and fires a turn.
    public static func meaningfulTranscript(_ raw: String, speaker: Speaker) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        if speaker == .me {
            // Strip only the trailing punctuation the transcriber actually emits; no apostrophe (it
            // belongs inside contractions, and trimming it could mangle a legitimately-quoted word).
            let normalized = trimmed.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?…\" "))
            guard !hallucinationDenylist.contains(normalized) else { return nil }
        }
        return trimmed
    }
}
