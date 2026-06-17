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
        return lines.last?.at
    }

    /// Seconds since the last spoken line (0 if none).
    public func silenceDuration(now: TimeInterval) -> TimeInterval {
        guard let last = lastSpeechTime else { return 0 }
        return max(0, now - last)
    }

    /// A timestamped window: lines within `seconds` of `now`, each `[mm:ss] speaker: text`.
    /// Sorted by timestamp: the two transcription sockets (mic/"me", system audio/"them") append
    /// independently and a slow utterance can complete — and so be appended — after a later one, so
    /// insertion order isn't time order. We sort by `.at` (stable on ties via the original index) so
    /// the coach always sees the conversation in the order it was actually spoken.
    public func renderWindow(seconds: TimeInterval, now: TimeInterval) -> String {
        lock.lock(); let snapshot = lines; lock.unlock()
        let cutoff = now - seconds
        return snapshot.enumerated()
            .filter { $0.element.at >= cutoff }
            .sorted { $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset }
            .map { "[\(Self.stamp($0.element.at))] \($0.element.speaker.rawValue): \($0.element.text)" }
            .joined(separator: "\n")
    }

    /// Lines from `index` onward, formatted like `renderWindow`, AND the line count rendered up to —
    /// returned together from a SINGLE locked snapshot so the caller's "advance to" index exactly
    /// matches the lines actually rendered (no duplicate-on-concurrent-append race). The index is
    /// clamped to a valid range (defensive against a stale caller index).
    public func renderFrom(index: Int) -> (text: String, upTo: Int) {
        lock.lock(); let snapshot = lines; lock.unlock()
        let start = min(max(0, index), snapshot.count)
        let text = snapshot[start...]
            .map { "[\(Self.stamp($0.at))] \($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
        return (text, snapshot.count)
    }

    static func stamp(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
