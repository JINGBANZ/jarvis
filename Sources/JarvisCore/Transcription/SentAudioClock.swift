import Foundation

/// Keeps each contiguous span of sent audio until the socket closes, including spans for
/// delayed finals. A final crossing a dropped capture chunk has no measured range.
public struct SentAudioClock: Sendable {
    private struct Span: Sendable {
        let captureOrigin: TimeInterval
        let offset: TimeInterval
        var end: TimeInterval
    }

    private var spans: [Span] = []
    private var sentDuration: TimeInterval = 0
    private var expectedNextSequence: UInt64?
    private var durationKnown = true

    public init() {}

    public mutating func recordSentAudio(sequenceNumber: UInt64, capturedAt: TimeInterval, duration: TimeInterval) {
        guard durationKnown, duration.isFinite, duration > 0 else {
            durationKnown = false
            return
        }
        defer { sentDuration += duration; expectedNextSequence = sequenceNumber &+ 1 }
        guard capturedAt.isFinite, capturedAt >= 0 else { return }
        if let last = spans.last, last.end == sentDuration, expectedNextSequence == sequenceNumber {
            spans[spans.count - 1].end = sentDuration + duration
        } else {
            spans.append(Span(captureOrigin: capturedAt, offset: sentDuration, end: sentDuration + duration))
        }
    }

    public func sessionTime(forOffset offset: TimeInterval) -> TimeInterval? {
        sessionInterval(SpeechInterval(startedAt: offset, endedAt: offset))?.startedAt
    }

    public func sessionInterval(_ speech: SpeechInterval?) -> SpeechInterval? {
        guard durationKnown, let speech,
              let span = spans.first(where: {
                  speech.startedAt >= $0.offset && speech.endedAt <= $0.end + 0.000_001
              }) else { return nil }
        return SpeechInterval(startedAt: span.captureOrigin + speech.startedAt - span.offset,
                              endedAt: span.captureOrigin + speech.endedAt - span.offset)
    }
}
