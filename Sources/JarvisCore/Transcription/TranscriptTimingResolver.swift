import Foundation

/// Keeps audio extents, never PCM. Local activity association is approximate and reusable across finals.
public struct TranscriptTimingResolver: Sendable {
    private var audioWindow: SpeechInterval?
    private var localStart: TimeInterval?
    private var localEnd: TimeInterval?

    public init() {}

    public mutating func recordAudio(startedAt: TimeInterval, endedAt: TimeInterval) {
        guard TranscriptLine.validTimestamp(startedAt), TranscriptLine.validTimestamp(endedAt),
              let interval = SpeechInterval(startedAt: startedAt, endedAt: endedAt) else { return }
        audioWindow = SpeechInterval(startedAt: min(audioWindow?.startedAt ?? startedAt, startedAt),
                                     endedAt: max(audioWindow?.endedAt ?? endedAt, endedAt)) ?? interval
    }

    public mutating func resetAudioWindow() { audioWindow = nil }

    public mutating func recordLocalSpeech(_ event: LocalSpeechEvent) {
        switch event {
        case .started(let at):
            guard TranscriptLine.validTimestamp(at) else { return }
            localStart = at
            localEnd = nil
        case .ended(let startedAt, let endedAt, _):
            guard TranscriptLine.validTimestamp(startedAt) else { return }
            if let endedAt {
                guard TranscriptLine.validTimestamp(endedAt), endedAt >= startedAt else { return }
            }
            localStart = startedAt
            localEnd = endedAt
        }
    }

    public func resolve(
        startedAt: TimeInterval?, endedAt: TimeInterval?, observedAt: TimeInterval,
        source: TranscriptTimingSource, useLocalActivityEstimate: Bool
    ) -> (interval: SpeechInterval, source: TranscriptTimingSource) {
        let knownEnd = audioWindow?.endedAt ?? [startedAt, endedAt]
            .compactMap { $0 }.filter { TranscriptLine.validTimestamp($0) }.max() ?? 0
        let observation = TranscriptLine.validTimestamp(observedAt) ? observedAt : knownEnd
        let ceiling = max(observation, audioWindow?.endedAt ?? 0)
        func usable(_ value: TimeInterval?) -> TimeInterval? {
            value.flatMap { TranscriptLine.validTimestamp($0) && $0 <= ceiling ? $0 : nil }
        }
        let start = usable(startedAt)
        let end = usable(endedAt)
        if let start, let end, let interval = SpeechInterval(startedAt: start, endedAt: end) {
            return (interval, source)
        }
        let activityStart = useLocalActivityEstimate ? usable(localStart) : nil
        let activityEnd = useLocalActivityEstimate ? usable(localEnd) : nil
        if let localStart = start ?? activityStart, let localEnd = end ?? activityEnd,
           let interval = SpeechInterval(startedAt: localStart, endedAt: localEnd) {
            return (interval, .localActivityEstimate)
        }
        let lower = usable(audioWindow?.startedAt) ?? 0
        let upper = usable(audioWindow?.endedAt) ?? lower
        let compatibleActivityStart = activityStart.flatMap { value in
            end == nil || value <= end! ? value : nil
        }
        let fallbackStart = start ?? compatibleActivityStart ?? min(lower, end ?? activityEnd ?? lower)
        let fallbackEnd = (end ?? activityEnd).flatMap { $0 >= fallbackStart ? $0 : nil } ?? max(fallbackStart, upper)
        return (SpeechInterval(startedAt: fallbackStart, endedAt: fallbackEnd)!, .audioWindowEstimate)
    }
}
