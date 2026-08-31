import CoreAudio
import Foundation
import JarvisCore

/// Process-scoped system-audio capture for the explicit benchmark mode. It taps only this app's
/// synthetic playback process, never opens a microphone, and never retains PCM after delivery.
///
/// `@unchecked Sendable`: lifecycle/device ownership is guarded by `lock`; audio state is confined
/// to the single IOProc while running, and `AudioDeviceStop` drains it before teardown mutates state.
final class SystemAudioBenchmarkCapture: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case unsupported
        case processAudioObjectUnavailable
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case sampleRateUnavailable
        case conversionUnavailable
        case callbackCreationFailed(OSStatus)
        case startFailed(OSStatus)

        var description: String {
            switch self {
            case .unsupported: "System-audio benchmark capture requires macOS 14.2 or later"
            case .processAudioObjectUnavailable:
                "Jarvis's synthetic playback process was not visible to Core Audio"
            case .tapCreationFailed(let status): "Process-tap creation failed (OSStatus \(status))"
            case .aggregateCreationFailed(let status):
                "Tap-only aggregate creation failed (OSStatus \(status))"
            case .sampleRateUnavailable: "Could not read the benchmark tap sample rate"
            case .conversionUnavailable: "Could not prepare benchmark audio conversion"
            case .callbackCreationFailed(let status):
                "Benchmark audio callback creation failed (OSStatus \(status))"
            case .startFailed(let status): "Benchmark audio device start failed (OSStatus \(status))"
            }
        }
    }

    private let onChunk: @Sendable (Data, UInt64, Int, TimeInterval, [LocalSpeechEvent]) -> Void
    private let lock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var downToWire: Resampler?
    /// Confined to `deliveryQueue`, never the IOProc: it runs a Core ML prediction. Same contract as
    /// the production path in `AggregateEchoCapture`.
    private var turnDetector: LocalTurnDetector?
    /// IOProc-only state while the device runs; teardown first drains that callback.
    private var sequence: UInt64 = 0
    /// Keeps model inference off the realtime callback while preserving capture order, which the
    /// benchmark depends on for its turn boundaries.
    private let deliveryQueue = DispatchQueue(
        label: "jarvis.benchmark.delivery", qos: .userInitiated)

    init(
        onChunk: @escaping @Sendable (
            Data, UInt64, Int, TimeInterval, [LocalSpeechEvent]
        ) -> Void
    ) {
        self.onChunk = onChunk
    }

    func start() throws {
        guard #available(macOS 14.2, *) else { throw Failure.unsupported }
        lock.lock()
        defer { lock.unlock() }
        do {
            try buildLocked()
        } catch {
            teardownLocked()
            throw error
        }
    }

    func stop() {
        lock.lock()
        teardownLocked()
        lock.unlock()
    }

    @available(macOS 14.2, *)
    private func buildLocked() throws {
        guard let processObjectID = Self.currentProcessAudioObjectID() else {
            throw Failure.processAudioObjectUnavailable
        }
        let tapDescription = CATapDescription(
            monoMixdownOfProcesses: [processObjectID])
        tapDescription.name = "Jarvis transcription benchmark"
        tapDescription.isPrivate = true
        // Capture the fixture without sending its synthetic speech to the hardware output.
        tapDescription.muteBehavior = CATapMuteBehavior.muted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            throw Failure.tapCreationFailed(tapStatus)
        }
        tapID = tap

        let aggregateUID = "com.jarvis.transcription-benchmark.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Jarvis Transcription Benchmark",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: 1,
                ],
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            description as CFDictionary, &aggregate)
        guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
            throw Failure.aggregateCreationFailed(aggregateStatus)
        }
        aggregateID = aggregate

        guard let sampleRate = Self.nominalSampleRate(aggregate) else {
            throw Failure.sampleRateUnavailable
        }
        guard let downToWire = Resampler(
            fromHz: sampleRate,
            toHz: Double(TranscriptionAudioFormat.pcm16Mono.sampleRate)),
              let turnDetector = LocalTurnDetector(
                inputSampleRate: sampleRate, trailingSilenceDuration: 1.0) else {
            throw Failure.conversionUnavailable
        }
        self.downToWire = downToWire
        self.turnDetector = turnDetector

        var proc: AudioDeviceIOProcID?
        let callbackStatus = AudioDeviceCreateIOProcIDWithBlock(
            &proc, aggregate, nil
        ) { [weak self] _, input, _, _, _ in
            self?.handle(input)
        }
        guard callbackStatus == noErr, let proc else {
            throw Failure.callbackCreationFailed(callbackStatus)
        }
        procID = proc
        let startStatus = AudioDeviceStart(aggregate, proc)
        guard startStatus == noErr else { throw Failure.startFailed(startStatus) }
        jlog("Jarvis benchmark: process-scoped tap capture started at \(Int(sampleRate)) Hz")
    }

    private func teardownLocked() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        downToWire = nil
        turnDetector = nil
        sequence = 0
    }

    private func handle(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: list))
        guard let buffer = buffers.first,
              let downToWire,
              let turnDetector else { return }
        let nativeSamples = Self.monoInt16(buffer)
        guard !nativeSamples.isEmpty else { return }
        let capturedAt = Date().timeIntervalSince1970

        let wireSamples = downToWire.convert(nativeSamples)
        guard !wireSamples.isEmpty else { return }
        sequence &+= 1
        let sequence = sequence
        let sampleCount = wireSamples.count
        let commitAt = capturedAt + TimeInterval(sampleCount)
            / TimeInterval(TranscriptionAudioFormat.pcm16Mono.sampleRate)
        let data = wireSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        let onChunk = self.onChunk
        // Turn detection and delivery both hop off the realtime callback. The queue is serial, so
        // chunks stay in capture order; the runner supplies
        // `TranscriptionBenchmarkSessionRelay.enqueue`, which only binds this chunk to the relay's
        // own serial stream. Provider work never runs on the IOProc.
        deliveryQueue.async { [turnDetector] in
            let speechEvents = turnDetector
                .speechEvents(from: nativeSamples, capturedAt: capturedAt)
                .map { event -> LocalSpeechEvent in
                    switch event {
                    case .started(let startedAt): .started(at: startedAt)
                    case .ended(let startedAt, _): .ended(startedAt: startedAt, commitAt: commitAt)
                    }
                }
            onChunk(data, sequence, sampleCount, capturedAt, speechEvents)
        }
    }

    @available(macOS 14.2, *)
    private static func currentProcessAudioObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var processIdentifier = getpid()
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        for _ in 0..<40 {
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                &processIdentifier,
                &dataSize,
                &objectID)
            if status == noErr, objectID != kAudioObjectUnknown { return objectID }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(
            device, &address, 0, nil, &size, &rate) == noErr,
              rate > 0 else { return nil }
        return rate
    }

    private static func monoInt16(_ buffer: AudioBuffer) -> [Int16] {
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
        guard count > 0, let data = buffer.mData else { return [] }
        let samples = UnsafeBufferPointer(
            start: data.bindMemory(to: Float32.self, capacity: count),
            count: count)
        return AudioDownmix.monoInt16(
            Array(samples), channels: Int(buffer.mNumberChannels))
    }
}
