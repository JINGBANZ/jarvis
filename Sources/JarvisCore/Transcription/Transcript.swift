import Foundation

public enum Speaker: String, Sendable, Hashable {
    case me        // mic
    case them      // system audio
}

public struct TranscriptLine: Sendable {
    public let speaker: Speaker
    public let text: String
    public let interval: SpeechInterval
    public let timingIsEstimated: Bool
    public var at: TimeInterval { interval.startedAt }
    public var endedAt: TimeInterval { interval.endedAt }

    public init(speaker: Speaker, text: String, at: TimeInterval, endedAt: TimeInterval) {
        self.init(speaker: speaker, text: text, observedAt: at,
                  speechInterval: SpeechInterval(startedAt: at, endedAt: endedAt))
    }

    public init(speaker: Speaker, text: String, observedAt: TimeInterval, speechInterval: SpeechInterval?) {
        precondition(observedAt.isFinite && observedAt >= 0)
        self.speaker = speaker
        self.text = text
        // Receipt supplies a labelled point estimate, never a claimed speech duration.
        self.interval = speechInterval ?? SpeechInterval(startedAt: observedAt, endedAt: observedAt)!
        self.timingIsEstimated = speechInterval == nil
    }
}

/// `@unchecked Sendable`: `lock` guards `chronology`.
public final class RollingTranscript: @unchecked Sendable {
    public typealias Snapshot = (text: String, upTo: Int, lines: [TranscriptLine])

    private var chronology = ConversationChronology<TranscriptLine>()
    private var latestSpeechEnd: TimeInterval?
    private let lock = NSLock()

    public init() {}

    /// Returns the line's exclusive insertion boundary, which identifies it to a turn trigger.
    @discardableResult
    public func append(_ line: TranscriptLine) -> Int {
        lock.lock(); defer { lock.unlock() }
        chronology.append(line, occurredAt: line.at)
        let end = line.endedAt
        latestSpeechEnd = max(latestSpeechEnd ?? end, end)
        return chronology.count
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return chronology.count
    }

    public var lastSpeechTime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return latestSpeechEnd
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

    /// Sorts by measured start or receipt time (stable on ties) across both speaker streams.
    static func render<S: Sequence>(_ lines: S) -> String where S.Element == TranscriptLine {
        renderChronological(ConversationChronology<TranscriptLine>.ordered(lines, occurredAt: \.at))
    }

    private static func renderChronological<S: Sequence>(_ lines: S) -> String
    where S.Element == TranscriptLine {
        lines
            .map { line in
                let timing = line.timingIsEstimated
                    ? "[\(stamp(line.at)); estimated from transcript receipt]"
                    : "[\(stamp(line.at))-\(stamp(line.endedAt))]"
                return "\(timing) \(line.speaker.rawValue): \(line.text)"
            }
            .joined(separator: "\n")
    }

    static func stamp(_ t: TimeInterval) -> String {
        guard let total = Int(exactly: t.rounded(.down)) else { return "\(t)s" }
        return String(format: "%02lld:%02lld", total / 60, total % 60)
    }
}
