#if JARVIS_LIVE_E2E // Debug builds only: see liveE2ESettings in Package.swift
/// Owns no clock: the caller calls `tick()` once per 20 ms of real time.
public struct AudioTimeline: Sendable {
    /// Microphone first, because `tick()` emits in `allCases` order.
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
        public let clipStarted: Bool
        public let clipEnded: Bool
    }

    private struct ScheduledClip: Sendable {
        let startTick: Int
        let samples: [Int16]
    }

    private struct StreamState: Sendable {
        var lastSequence: UInt64 = 0
        var clips: [ScheduledClip] = []
        var nextFreeTick = 0
    }

    private var streams: [Stream: StreamState]
    private var elapsedTicks = 0

    /// Streams outside `liveStreams` never emit a chunk, like a dead device.
    public init(liveStreams: Set<Stream>) {
        streams = Dictionary(uniqueKeysWithValues: liveStreams.map { ($0, StreamState()) })
    }

    /// Starts after `afterChunks` ticks or after the stream's queued clips, whichever is later.
    /// False for an empty clip or a stream that isn't live. Clips start on a chunk boundary, so
    /// both flags on one chunk always mean one whole short clip.
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

    public var isIdle: Bool {
        streams.values.allSatisfy { $0.clips.isEmpty }
    }
}
#endif
