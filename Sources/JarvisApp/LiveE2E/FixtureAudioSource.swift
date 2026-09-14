import Foundation
import JarvisCore

/// An `AudioSource` that plays scheduled speech clips into the two transcription streams in real
/// time, with digital silence in between, the way a quiet capture device delivers frames.
///
/// A 20 ms timer drives an `AudioTimeline`. Each chunk is stamped on the same Unix-time base the
/// production capture uses, delivered captured-before-clean with one sequence number, and followed
/// by local speech edges at clip boundaries so a client-commit transcription model would also close
/// its turns. A stream the timeline leaves dead delivers nothing, which is what a device that never
/// produces frames looks like to capture readiness.
///
/// `@unchecked Sendable`: the timeline, the timer, and the tick bookkeeping are touched only on
/// `queue`; the delivery closures are immutable; the two recovery callbacks are assigned before
/// `start` and never fired, because fixture frames cannot lose a device.
final class FixtureAudioSource: AudioSource, @unchecked Sendable {
    var onUnavailable: (@Sendable (String) -> Void)?
    var onRecoveryStateChange: (@Sendable (Bool) -> Void)?

    private static let chunkDuration =
        TimeInterval(AudioTimeline.chunkSampleCount) / TimeInterval(AudioTimeline.sampleRate)

    private let audioFormat: TranscriptionAudioFormat
    private let delivery: AudioDelivery
    private let queue = DispatchQueue(label: "jarvis.fixture-audio", qos: .userInitiated)
    private var timeline: AudioTimeline
    private var timer: DispatchSourceTimer?
    private var startedAt: TimeInterval = 0
    private var emittedTicks = 0
    private var clipStartedAt: [AudioTimeline.Stream: TimeInterval] = [:]

    init(
        liveStreams: Set<AudioTimeline.Stream>,
        audioFormat: TranscriptionAudioFormat,
        delivery: AudioDelivery
    ) {
        timeline = AudioTimeline(liveStreams: liveStreams)
        self.audioFormat = audioFormat
        self.delivery = delivery
    }

    func start() -> String? {
        guard audioFormat.sampleRate == AudioTimeline.sampleRate else {
            return "Fixture speech is synthesized at \(AudioTimeline.sampleRate) Hz only."
        }
        queue.sync {
            timer?.cancel()
            startedAt = Date().timeIntervalSince1970
            emittedTicks = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.emitDueChunks() }
            self.timer = timer
            timer.resume()
        }
        return nil
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// Play `samples` on `stream` once `afterSeconds` have passed, or after whatever that stream is
    /// already playing.
    func schedule(_ samples: [Int16], on stream: AudioTimeline.Stream, afterSeconds: TimeInterval = 0) {
        let afterChunks = Int((afterSeconds / Self.chunkDuration).rounded())
        queue.async {
            self.timeline.schedule(samples, on: stream, afterChunks: afterChunks)
        }
    }

    /// Emit every chunk whose time has come, so a late timer fire catches up instead of drifting.
    private func emitDueChunks() {
        let due = Int((Date().timeIntervalSince1970 - startedAt) / Self.chunkDuration) + 1
        while emittedTicks < due {
            let capturedAt = startedAt + TimeInterval(emittedTicks) * Self.chunkDuration
            emittedTicks += 1
            for chunk in timeline.tick() {
                deliver(chunk, capturedAt: capturedAt)
            }
        }
    }

    private func deliver(_ chunk: AudioTimeline.Chunk, capturedAt: TimeInterval) {
        let data = chunk.samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let sampleCount = chunk.samples.count
        switch chunk.stream {
        case .microphone:
            delivery.onMicCaptured(chunk.sequence, sampleCount, capturedAt)
            delivery.onMicClean(data, chunk.sequence, capturedAt)
        case .system:
            delivery.onSystemCaptured(chunk.sequence, sampleCount, capturedAt)
            delivery.onSystem(data, chunk.sequence, capturedAt)
        }
        for event in speechEdges(of: chunk, capturedAt: capturedAt) {
            switch chunk.stream {
            case .microphone: delivery.onMicSpeechEvent(event, chunk.sequence)
            case .system: delivery.onSystemSpeechEvent(event, chunk.sequence)
            }
        }
    }

    private func speechEdges(
        of chunk: AudioTimeline.Chunk, capturedAt: TimeInterval
    ) -> [LocalSpeechEvent] {
        var events: [LocalSpeechEvent] = []
        if chunk.clipStarted {
            clipStartedAt[chunk.stream] = capturedAt
            events.append(.started(at: capturedAt))
        }
        if chunk.clipEnded {
            events.append(.ended(
                startedAt: clipStartedAt[chunk.stream] ?? capturedAt,
                commitAt: capturedAt + Self.chunkDuration))
            clipStartedAt[chunk.stream] = nil
        }
        return events
    }
}
