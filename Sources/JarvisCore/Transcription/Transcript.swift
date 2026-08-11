import Foundation

public enum Speaker: String, Sendable, Hashable {
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
    private var chronology = ConversationChronology<TranscriptLine>()
    private let lock = NSLock()

    public init() {}

    public func append(_ line: TranscriptLine) {
        lock.lock(); defer { lock.unlock() }
        chronology.append(line, occurredAt: line.at)
    }

    /// Number of lines recorded — used as the index boundary for server-side delta sending.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return chronology.count
    }

    public var lastSpeechTime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return chronology.latestOccurredAt
    }

    /// Seconds since the last spoken line. Callers pass session-relative time, so with **no speech yet
    /// this session** the user has been silent the *whole* session — return the elapsed `now`, not 0.
    /// Returning 0 would peg the "are you stuck?" silence check below its interval forever, so it would
    /// never fire before the first utterance (a user who opens Jarvis and works silently got no nudges).
    public func silenceDuration(now: TimeInterval) -> TimeInterval {
        guard let last = lastSpeechTime else { return max(0, now) }
        return max(0, now - last)
    }

    /// The delta since `index`: the rendered text, the line count rendered up to, AND the raw lines —
    /// returned together from a SINGLE locked snapshot so the caller's "advance to" index exactly
    /// matches the lines actually rendered (no duplicate-on-concurrent-append race). The index is
    /// clamped to a valid range (defensive against a stale caller index). The raw `lines` are what the
    /// coach loop's substance gate inspects (see `TurnSubstance`) before spending a brain request.
    public func renderFrom(index: Int) -> (text: String, upTo: Int, lines: [TranscriptLine]) {
        lock.lock(); let snapshot = chronology.snapshot(fromInsertionIndex: index); lock.unlock()
        let insertionOrderedLines = snapshot.insertionOrderedItems.map(\.element)
        let chronologicalLines = snapshot.chronologicalItems.map(\.element)
        return (
            Self.renderChronological(chronologicalLines),
            snapshot.upToInsertionIndex,
            insertionOrderedLines)
    }

    /// Render lines as `[mm:ss] speaker: text`, one per line, in SPOKEN order. The two transcription
    /// sockets (mic/"me", system audio/"them") append independently and a slow utterance can complete
    /// — and so be appended — after a later one, so insertion order isn't time order. We sort by `.at`
    /// (stable on ties via the original index) so the coach always sees the order things were said.
    static func render<S: Sequence>(_ lines: S) -> String where S.Element == TranscriptLine {
        renderChronological(ConversationChronology<TranscriptLine>.ordered(lines, occurredAt: \.at))
    }

    private static func renderChronological<S: Sequence>(_ lines: S) -> String
    where S.Element == TranscriptLine {
        lines
            .map { "[\(stamp($0.at))] \($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }

    static func stamp(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
