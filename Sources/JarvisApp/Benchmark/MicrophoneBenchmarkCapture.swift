import AVFoundation
import Foundation
import JarvisCore

@MainActor
final class MicrophoneBenchmarkCapture {
    enum Failure: Error, CustomStringConvertible {
        case alreadyStarted
        case permissionDenied
        case microphoneUnavailable
        case conversionUnavailable

        var description: String {
            switch self {
            case .alreadyStarted: "Microphone benchmark capture can only be started once"
            case .permissionDenied: "Microphone permission is required for the microphone benchmark"
            case .microphoneUnavailable: "The default microphone has no usable audio format"
            case .conversionUnavailable: "Could not prepare microphone benchmark audio conversion"
            }
        }
    }

    private let onChunk: @Sendable (Data, UInt64, Int, TimeInterval, [LocalSpeechEvent]) -> Void
    private var engine: AVAudioEngine?
    private var delivery: Delivery?
    private var started = false
    private var stopped = false

    var droppedChunkCount: Int { delivery?.droppedChunkCount ?? 0 }

    init(
        onChunk: @escaping @Sendable (
            Data, UInt64, Int, TimeInterval, [LocalSpeechEvent]
        ) -> Void
    ) {
        self.onChunk = onChunk
    }

    func start() async throws {
        guard !started else { throw Failure.alreadyStarted }
        started = true
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            // ghost-mode-allowed: unavoidable macOS privacy prompt for explicit microphone benchmark.
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw Failure.permissionDenied
            }
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw Failure.permissionDenied
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0, format.commonFormat == .pcmFormatFloat32,
              let tapFormat = AVAudioFormat(
                standardFormatWithSampleRate: format.sampleRate,
                channels: format.channelCount) else {
            throw Failure.microphoneUnavailable
        }
        guard let delivery = Delivery(sampleRate: format.sampleRate, onChunk: onChunk) else {
            throw Failure.conversionUnavailable
        }
        self.delivery = delivery
        self.engine = engine
        input.installTap(onBus: 0, bufferSize: 2_048, format: tapFormat) { buffer, time in
            let now = Date().timeIntervalSince1970
            let capturedAt = time.isHostTimeValid
                ? now - (AVAudioTime.seconds(forHostTime: mach_absolute_time())
                    - AVAudioTime.seconds(forHostTime: time.hostTime))
                : now - Double(buffer.frameLength) / buffer.format.sampleRate
            delivery.enqueue(buffer, capturedAt: capturedAt)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    /// Call from the owner, never from `onChunk`, which is drained before this returns.
    func stop() {
        stopped = true
        delivery?.closeAdmission()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        delivery?.drain()
    }

    // @unchecked Sendable: lock guards admission, pending samples, and loss count; the serial
    // queue exclusively owns converter, detector, and sequence after initialization. Closing
    // admission under that lock precedes draining, so no tap callback can enqueue after drain.
    private final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(
            label: "jarvis.benchmark.microphone.delivery", qos: .userInitiated)
        private let maximumPendingSamples: Int
        private let resampler: Resampler
        private let turnDetector: LocalTurnDetector
        private let onChunk: @Sendable (Data, UInt64, Int, TimeInterval, [LocalSpeechEvent]) -> Void
        private var accepting = true
        private var pendingSamples = 0
        private var droppedChunks = 0
        private var sequence: UInt64 = 0

        var droppedChunkCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return droppedChunks
        }

        init?(
            sampleRate: Double,
            onChunk: @escaping @Sendable (
                Data, UInt64, Int, TimeInterval, [LocalSpeechEvent]
            ) -> Void
        ) {
            guard let resampler = Resampler(
                fromHz: sampleRate,
                toHz: Double(TranscriptionAudioFormat.pcm16Mono24k.sampleRate)),
                  let turnDetector = LocalTurnDetector(
                    inputSampleRate: sampleRate, trailingSilenceDuration: 1.0) else { return nil }
            maximumPendingSamples = Int(sampleRate)
            self.resampler = resampler
            self.turnDetector = turnDetector
            self.onChunk = onChunk
        }

        func enqueue(_ buffer: AVAudioPCMBuffer, capturedAt: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            guard accepting else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            guard count <= maximumPendingSamples - pendingSamples,
                  let channels = buffer.floatChannelData else {
                droppedChunks += 1
                return
            }
            let channelCount = Int(buffer.format.channelCount)
            var samples = [Int16](repeating: 0, count: count)
            for index in 0..<count {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += channels[channel][index] }
                let value = sum / Float(channelCount)
                samples[index] = value.isFinite ? Int16(max(-1, min(1, value)) * 32_767) : 0
            }
            pendingSamples += count
            let nativeSamples = samples
            queue.async { [self] in
                deliver(nativeSamples, capturedAt: capturedAt)
                lock.lock()
                pendingSamples -= count
                lock.unlock()
            }
        }

        func closeAdmission() {
            lock.lock()
            accepting = false
            lock.unlock()
        }

        func drain() {
            queue.sync {}
        }

        private func deliver(_ samples: [Int16], capturedAt: TimeInterval) {
            let wireSamples = resampler.convert(samples)
            guard !wireSamples.isEmpty else { return }
            sequence &+= 1
            let commitAt = capturedAt + Double(wireSamples.count)
                / Double(TranscriptionAudioFormat.pcm16Mono24k.sampleRate)
            let events = turnDetector.speechEvents(from: samples, capturedAt: capturedAt)
                .map { event -> LocalSpeechEvent in
                    switch event {
                    case .started(let startedAt): .started(at: startedAt)
                    case .ended(let startedAt, _): .ended(startedAt: startedAt, commitAt: commitAt)
                    }
                }
            let data = wireSamples.withUnsafeBufferPointer { Data(buffer: $0) }
            onChunk(data, sequence, wireSamples.count, capturedAt, events)
        }
    }
}
