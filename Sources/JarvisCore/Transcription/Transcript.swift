import Foundation

public enum Speaker: String, Sendable, Hashable {
    case me        // mic
    case them      // system audio
}

public struct TranscriptLine: Sendable {
    public let speaker: Speaker
    public let text: String
    public let interval: SpeechInterval
    public let timingSource: TranscriptTimingSource
    public var at: TimeInterval { interval.startedAt }
    public var endedAt: TimeInterval { interval.endedAt }

    public init(speaker: Speaker, text: String, at: TimeInterval, endedAt: TimeInterval) {
        let interval = SpeechInterval(startedAt: at, endedAt: endedAt)
        let knownBoundary = Self.validTimestamp(at) ? at : Self.validTimestamp(endedAt) ? endedAt : 0
        self.init(speaker: speaker, text: text,
                  interval: interval ?? SpeechInterval(startedAt: knownBoundary, endedAt: knownBoundary)!,
                  timingSource: interval == nil ? .audioWindowEstimate : .providerOffsets)
    }

    public init(speaker: Speaker, text: String, interval: SpeechInterval, timingSource: TranscriptTimingSource) {
        self.speaker = speaker
        self.text = text
        if Self.validTimestamp(interval.startedAt), Self.validTimestamp(interval.endedAt) {
            self.interval = interval
            self.timingSource = timingSource
        } else {
            let knownBoundary = Self.validTimestamp(interval.startedAt) ? interval.startedAt : 0
            self.interval = SpeechInterval(startedAt: knownBoundary, endedAt: knownBoundary)!
            self.timingSource = .audioWindowEstimate
        }
    }

    static func validTimestamp(_ time: TimeInterval) -> Bool {
        time.isFinite && time >= 0 && Int(exactly: time.rounded(.down)) != nil
    }
}

/// `@unchecked Sendable`: `lock` guards `chronology`.
public final class RollingTranscript: @unchecked Sendable {
    public typealias Snapshot = (text: String, upTo: Int, lines: [TranscriptLine])

    private var chronology = ConversationChronology<TranscriptLine>()
    private var latestSpeechEnd: TimeInterval?
    private var activeSpeakers: Set<Speaker> = []
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

    public func recordLocalSpeech(_ event: LocalSpeechEvent, speaker: Speaker) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .started(let at):
            guard TranscriptLine.validTimestamp(at) else { return }
            activeSpeakers.insert(speaker)
            latestSpeechEnd = max(latestSpeechEnd ?? at, at)
        case .ended(_, let measuredEnd, let commitAt):
            let endedAt = measuredEnd ?? commitAt
            guard TranscriptLine.validTimestamp(endedAt) else { return }
            activeSpeakers.remove(speaker)
            latestSpeechEnd = max(latestSpeechEnd ?? endedAt, endedAt)
        }
    }

    public func finishLocalSpeech(speaker: Speaker) {
        lock.lock(); defer { lock.unlock() }
        activeSpeakers.remove(speaker)
    }

    public var lastSpeechTime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return latestSpeechEnd
    }

    /// `now` is session-relative. With no speech yet this returns `now`, not 0, so the silence
    /// check can fire before the first utterance.
    public func silenceDuration(now: TimeInterval) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard activeSpeakers.isEmpty else { return 0 }
        guard let last = latestSpeechEnd else { return max(0, now) }
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

    /// Sorts by segment start (stable on ties) across both speaker streams.
    static func render<S: Sequence>(_ lines: S) -> String where S.Element == TranscriptLine {
        renderChronological(ConversationChronology<TranscriptLine>.ordered(lines, occurredAt: \.at))
    }

    private static func renderChronological<S: Sequence>(_ lines: S) -> String
    where S.Element == TranscriptLine {
        lines
            .map { line in
                "[\(stamp(line.at))-\(stamp(line.endedAt))] \(line.speaker.rawValue): \(line.text)"
            }
            .joined(separator: "\n")
    }

    static func stamp(_ t: TimeInterval) -> String {
        guard let total = Int(exactly: t.rounded(.down)) else { return "\(t)s" }
        return String(format: "%02lld:%02lld", total / 60, total % 60)
    }
}
