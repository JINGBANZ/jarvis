#if JARVIS_LIVE_E2E // Debug builds only: see liveE2ESettings in Package.swift
import Foundation
import JarvisCore

/// `@unchecked Sendable`: mutable state is touched only on `queue`, and the recovery callbacks are
/// set before `start` and never fired.
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

    /// Starts after `afterSeconds` or after what `stream` already has queued, whichever is later.
    func schedule(_ samples: [Int16], on stream: AudioTimeline.Stream, afterSeconds: TimeInterval = 0) {
        let afterChunks = Int((afterSeconds / Self.chunkDuration).rounded())
        queue.async {
            self.timeline.schedule(samples, on: stream, afterChunks: afterChunks)
        }
    }

    /// Emits every due chunk, so a late timer fire catches up instead of drifting.
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
        // Production order: captured before clean, both with the chunk's sequence number.
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
#endif
