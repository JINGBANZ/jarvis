#if JARVIS_LIVE_E2E // Debug builds only: see liveE2ESettings in Package.swift
/// Pure chunk scheduling for the live e2e fixture audio source.
///
/// Feeds two 24 kHz Int16 mono streams in 20 ms chunks. It owns no clock: the caller calls `tick()`
/// once per 20 ms of real time, so the timeline stays deterministic and testable offline.
public struct AudioTimeline: Sendable {
    /// Declared microphone first because `tick()` emits in `allCases` order.
    public enum Stream: Sendable, Hashable, CaseIterable {
        case microphone
        case system
    }

    public static let sampleRate = 24_000
    public static let chunkSampleCount = 480

    public struct Chunk: Sendable, Equatable {
        public let stream: Stream
        /// Per stream, starts at 1, exactly +1 per chunk.
        public let sequence: UInt64
        /// Always `chunkSampleCount` samples; silence fills.
        public let samples: [Int16]
        /// This chunk holds a clip's first sample.
        public let clipStarted: Bool
        /// This chunk holds a clip's last sample.
        public let clipEnded: Bool
    }

    private struct ScheduledClip: Sendable {
        let startTick: Int
        let samples: [Int16]
    }

    private struct StreamState: Sendable {
        var lastSequence: UInt64 = 0
        var clips: [ScheduledClip] = []
        /// The first tick no queued clip occupies.
        var nextFreeTick = 0
    }

    private var streams: [Stream: StreamState]
    /// Ticks emitted so far; the next `tick()` is tick number `elapsedTicks`.
    private var elapsedTicks = 0

    /// Streams outside `liveStreams` never emit a chunk (a dead device, as readiness sees it).
    public init(liveStreams: Set<Stream>) {
        streams = Dictionary(uniqueKeysWithValues: liveStreams.map { ($0, StreamState()) })
    }

    /// Queue `samples` on `stream`, starting `afterChunks` ticks from now, or right after whatever is
    /// already playing or queued on that stream, whichever is later. Returns false (and queues
    /// nothing) for an empty clip or a stream that is not live.
    ///
    /// `afterChunks: 0` puts the clip's first sample in the very next `tick()`. A clip always starts
    /// on a chunk boundary, so a queued clip begins in the chunk after the one holding the previous
    /// clip's last sample rather than mid-chunk: one chunk never carries the end of one clip and the
    /// start of the next, which keeps both flags set on one chunk meaning only "a whole short clip".
    @discardableResult
    public mutating func schedule(_ samples: [Int16], on stream: Stream, afterChunks: Int = 0) -> Bool {
        precondition(afterChunks >= 0, "afterChunks must not be negative")
        guard !samples.isEmpty, var state = streams[stream] else { return false }
        let startTick = max(elapsedTicks + afterChunks, state.nextFreeTick)
        let chunkCount = (samples.count + Self.chunkSampleCount - 1) / Self.chunkSampleCount
        state.clips.append(ScheduledClip(startTick: startTick, samples: samples))
        state.nextFreeTick = startTick + chunkCount
        streams[stream] = state
        return true
    }

    /// One 20 ms step: one chunk per live stream, microphone before system.
    public mutating func tick() -> [Chunk] {
        var chunks: [Chunk] = []
        for stream in Stream.allCases {
            guard var state = streams[stream] else { continue }
            var samples = [Int16](repeating: 0, count: Self.chunkSampleCount)
            var clipStarted = false
            var clipEnded = false
            if let clip = state.clips.first, clip.startTick <= elapsedTicks {
                let offset = (elapsedTicks - clip.startTick) * Self.chunkSampleCount
                let end = min(offset + Self.chunkSampleCount, clip.samples.count)
                samples.replaceSubrange(0..<(end - offset), with: clip.samples[offset..<end])
                clipStarted = offset == 0
                clipEnded = end == clip.samples.count
                if clipEnded {
                    state.clips.removeFirst()
                }
            }
            state.lastSequence += 1
            chunks.append(Chunk(
                stream: stream,
                sequence: state.lastSequence,
                samples: samples,
                clipStarted: clipStarted,
                clipEnded: clipEnded))
            streams[stream] = state
        }
        elapsedTicks += 1
        return chunks
    }

    /// True when nothing is playing or queued on any stream.
    public var isIdle: Bool {
        streams.values.allSatisfy { $0.clips.isEmpty }
    }
}
#endif
