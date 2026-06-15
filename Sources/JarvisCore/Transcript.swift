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
    public func renderWindow(seconds: TimeInterval, now: TimeInterval) -> String {
        lock.lock(); let snapshot = lines; lock.unlock()
        let cutoff = now - seconds
        return snapshot
            .filter { $0.at >= cutoff }
            .map { "[\(Self.stamp($0.at))] \($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Lines from `index` onward, formatted like `renderWindow`. Used to send only the NEW lines when
    /// a server-side conversation already holds the earlier ones — tracked by index, so there is no
    /// clock-domain ambiguity. The index is clamped to a valid range (defensive against a stale
    /// caller index).
    public func renderFrom(index: Int) -> String {
        lock.lock(); let snapshot = lines; lock.unlock()
        let start = min(max(0, index), snapshot.count)
        return snapshot[start...]
            .map { "[\(Self.stamp($0.at))] \($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }

    static func stamp(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
