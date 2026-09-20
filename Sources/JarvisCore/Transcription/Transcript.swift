import Foundation

public enum Speaker: String, Sendable, Hashable {
    case me        // mic
    case them      // system audio
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

/// `@unchecked Sendable`: `lock` guards `chronology`.
public final class RollingTranscript: @unchecked Sendable {
    public typealias Snapshot = (text: String, upTo: Int, lines: [TranscriptLine])

    private var chronology = ConversationChronology<TranscriptLine>()
    private let lock = NSLock()

    public init() {}

    /// Returns the line's exclusive insertion boundary, which identifies it to a turn trigger.
    @discardableResult
    public func append(_ line: TranscriptLine) -> Int {
        lock.lock(); defer { lock.unlock() }
        chronology.append(line, occurredAt: line.at)
        return chronology.count
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return chronology.count
    }

    public var lastSpeechTime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return chronology.latestOccurredAt
    }

    /// `now` is session-relative. With no speech yet this returns `now`, not 0, so the silence
    /// check can fire before the first utterance.
    public func silenceDuration(now: TimeInterval) -> TimeInterval {
        guard let last = lastSpeechTime else { return max(0, now) }
        return max(0, now - last)
    }

    /// All three values come from one locked snapshot, so `upTo` matches the rendered lines even
    /// under a concurrent append. `index` is clamped.
    public func renderFrom(index: Int) -> Snapshot {
        lock.lock(); let snapshot = chronology.snapshot(fromInsertionIndex: index); lock.unlock()
        let insertionOrderedLines = snapshot.insertionOrderedItems.map(\.element)
        let chronologicalLines = snapshot.chronologicalItems.map(\.element)
        return (
            Self.renderChronological(chronologicalLines),
            snapshot.upToInsertionIndex,
            insertionOrderedLines)
    }

    /// Sorts by `.at` (stable on ties): the two speakers append independently, so insertion order
    /// isn't spoken order.
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
