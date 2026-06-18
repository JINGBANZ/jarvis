import Foundation

public enum Speaker: String, Sendable {
    case me        // the user thinking aloud (mic)
    case them      // the other side of a call (system audio)
}

public struct TranscriptLine: Sendable {
    public let speaker: Speaker
    public let text: String
    /// Seconds since session start.
    public let at: TimeInterval
    public init(speaker: Speaker, text: String, at: TimeInterval) {
        self.speaker = speaker
        self.text = text
        self.at = at
    }
}

/// Holds the session transcript and renders a recent, timestamped window for the model.
public final class RollingTranscript: @unchecked Sendable {
    private var lines: [TranscriptLine] = []
    private let lock = NSLock()

    public init() {}

    public func append(_ line: TranscriptLine) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
    }

    /// Number of lines recorded — used as the index boundary for server-side delta sending.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return lines.count
    }

    public var lastSpeechTime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        // Latest by SPOKEN time, not last-appended: the two sockets append out of time order (a slow
        // "them" utterance can land after a later "me" line), so `lines.last.at` can be stale. Using
        // the true latest keeps silenceDuration — and the "are you stuck?" guard built on it — honest.
        return lines.map(\.at).max()
    }

    /// Seconds since the last spoken line (0 if none).
    public func silenceDuration(now: TimeInterval) -> TimeInterval {
        guard let last = lastSpeechTime else { return 0 }
        return max(0, now - last)
    }

    /// A timestamped window: lines within `seconds` of `now`, each `[mm:ss] speaker: text`,
    /// rendered in spoken order (see `render`). Speaker bleed is dropped first (see `withoutBleed`).
    public func renderWindow(seconds: TimeInterval, now: TimeInterval) -> String {
        lock.lock(); let snapshot = lines; lock.unlock()
        let cutoff = now - seconds
        return Self.render(Self.withoutBleed(snapshot).filter { $0.at >= cutoff })
    }

    /// Lines from `index` onward, formatted like `renderWindow`, AND the line count rendered up to —
    /// returned together from a SINGLE locked snapshot so the caller's "advance to" index exactly
    /// matches the lines actually rendered (no duplicate-on-concurrent-append race). The index is
    /// clamped to a valid range (defensive against a stale caller index).
    public func renderFrom(index: Int) -> (text: String, upTo: Int) {
        lock.lock(); let snapshot = lines; lock.unlock()
        let start = min(max(0, index), snapshot.count)
        // Same spoken-order rendering as renderWindow, so the conversation-mode delta and the full
        // window agree on ordering (the two sockets can append out of time order). Bleed is matched
        // against ALL `them` lines (its original may sit before `start`); `upTo` stays the raw count
        // so a dropped bleed line still advances the caller's index and is never re-sent.
        let kept = Self.withoutBleed(Array(snapshot[start...]), in: snapshot)
        return (Self.render(kept), snapshot.count)
    }

    /// Render lines as `[mm:ss] speaker: text`, one per line, in SPOKEN order. The two transcription
    /// sockets (mic/"me", system audio/"them") append independently and a slow utterance can complete
    /// — and so be appended — after a later one, so insertion order isn't time order. We sort by `.at`
    /// (stable on ties via the original index) so the coach always sees the order things were said.
    private static func render<S: Sequence>(_ lines: S) -> String where S.Element == TranscriptLine {
        lines.enumerated()
            .sorted { $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset }
            .map { "[\(stamp($0.element.at))] \($0.element.speaker.rawValue): \($0.element.text)" }
            .joined(separator: "\n")
    }

    static func stamp(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Speaker-bleed suppression
    //
    // On speakers (no headphones), the other side's voice plays out loud and the mic re-captures it,
    // so it's transcribed a SECOND time on the `me` socket — the same words, ~the same instant,
    // mis-attributed to the user. We drop that copy here, in the transcript, rather than running
    // acoustic echo cancellation on the audio: the coach only ever consumes the transcript, so this
    // is the smallest reliable place to fix the mis-attribution and it works on speakers OR
    // headphones with no fragile audio plumbing. Tuned conservatively — two people don't say the same
    // multi-word sentence within the same few seconds by chance, but short backchannels and genuinely
    // distinct or later lines are kept, so real user speech is never discarded. If real use ever
    // shows this isn't enough, reference-based AEC (Glass's approach) is the documented escalation.

    /// Seconds within which a `me` line must match a `them` line to count as bleed (bleed is
    /// simultaneous; a later restatement is real user speech).
    private static let bleedWindowSeconds: TimeInterval = 4
    /// Minimum word-set overlap (Jaccard) for a match. High on purpose: only near-verbatim copies.
    private static let bleedSimilarity = 0.8
    /// Don't treat matches on trivially short `them` lines as bleed — "okay"/"right"/"yes" are common
    /// real user backchannels, and a short bleed line is low-harm if it slips through.
    private static let bleedMinWords = 3

    /// `lines` with `me` bleed of any `them` line removed. Convenience for the full-window case.
    private static func withoutBleed(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        withoutBleed(lines, in: lines)
    }

    /// `candidates` with `me` bleed removed, matched against the `them` lines found in `all`.
    private static func withoutBleed(_ candidates: [TranscriptLine],
                                     in all: [TranscriptLine]) -> [TranscriptLine] {
        let them = all.filter { $0.speaker == .them }
        guard !them.isEmpty else { return candidates }
        return candidates.filter { !isBleed($0, amongThem: them) }
    }

    private static func isBleed(_ line: TranscriptLine, amongThem them: [TranscriptLine]) -> Bool {
        guard line.speaker == .me else { return false }
        let meWords = Set(normalizedWords(line.text))
        guard !meWords.isEmpty else { return false }
        for t in them where abs(line.at - t.at) <= bleedWindowSeconds {
            let themWords = Set(normalizedWords(t.text))
            guard themWords.count >= bleedMinWords else { continue }
            let union = meWords.union(themWords).count
            if union > 0, Double(meWords.intersection(themWords).count) / Double(union) >= bleedSimilarity {
                return true
            }
        }
        return false
    }

    /// Lowercased alphanumeric word tokens, so punctuation/casing differences between the clean `them`
    /// transcript and the degraded mic re-capture don't defeat the match.
    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
