import Foundation
import CoreAudio
import JarvisCore

/// Design: wiki/architecture.md#capture-device-rate-adaptation
///
/// AEC3 stays on for every route. Never bypass it for "headphones": a Bluetooth speaker looks like
/// one, and a wrong bypass readmits the echo.
///
/// `@unchecked Sendable`: audio state is touched only by the IOProc thread, and lifecycle is
/// serialized by `lock`, which the IOProc never takes. Teardown calls `AudioDeviceStop`, which
/// drains in-flight callbacks, before destroying anything.
final class AggregateEchoCapture: AudioSource, @unchecked Sendable {
    private struct SequencedAudioChunk: Sendable {
        let data: Data
        let sequence: UInt64
        let sampleCount: Int
        let capturedAt: TimeInterval
    }

    private let onMicCaptured: @Sendable (UInt64, Int, TimeInterval) -> Void
    private let onSystemCaptured: @Sendable (UInt64, Int, TimeInterval) -> Void
    private let onMicClean: @Sendable (Data, UInt64, TimeInterval) -> Void
    private let onSystem: @Sendable (Data, UInt64, TimeInterval) -> Void
    private let onMicSpeechEvent: @Sendable (LocalSpeechEvent, UInt64) -> Void
    private let onSystemSpeechEvent: @Sendable (LocalSpeechEvent, UInt64) -> Void
    var onUnavailable: (@Sendable (String) -> Void)?
    var onRecoveryStateChange: (@Sendable (Bool) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    private let aec = WebRTCEchoCanceller()          // adaptive; re-converges across route rebuilds
    private let audioFormat: TranscriptionAudioFormat
    private let micDown: Resampler?
    private let sysDown: Resampler?
    private let usesLocalTurnDetection: Bool
    /// Confined to `deliveryQueue`: Core ML inference must stay off the realtime IOProc thread.
    private let micTurnDetector: LocalTurnDetector?
    private let systemTurnDetector: LocalTurnDetector?
    /// Device-native to 48 kHz, nil when the device is already 48 kHz. Read by the IOProc; replaced
    /// only under `lock` while the device is stopped.
    private var micUp: Resampler?
    private var sysUp: Resampler?

    private static let aecRate = 48_000.0

    private let lock = NSLock()
    private let routeQueue = DispatchQueue(label: "jarvis.aec.routes")
    /// Routes often vanish briefly while macOS switches hardware; only an exhausted budget proves
    /// capture unusable.
    private var rebuildIncident = RetryIncident(schedule: RetrySchedule(
        maximumRetries: 6, initialDelay: 0.5, maximumDelay: 5))
    /// Confined to `routeQueue`.
    private var rebuildRecoveryInProgress = false
    /// One queue for both streams keeps the IOProc's callback order while moving work off the audio
    /// thread.
    private let deliveryQueue = DispatchQueue(label: "jarvis.aec.delivery", qos: .userInitiated)
    private var routeListener: AudioObjectPropertyListenerBlock?
    private var pendingRebuild: DispatchWorkItem?
    private var stopped = false
    /// IOProc-only, and kept across route rebuilds so a gap stays diagnosable.
    private var micSequence: UInt64 = 0
    private var systemSequence: UInt64 = 0

    init(audioFormat: TranscriptionAudioFormat,
         localTurnDetectionSilenceDuration: TimeInterval?,
         delivery: AudioDelivery) {
        self.audioFormat = audioFormat
        micDown = Resampler(fromHz: Self.aecRate, toHz: Double(audioFormat.sampleRate))
        sysDown = Resampler(fromHz: Self.aecRate, toHz: Double(audioFormat.sampleRate))
        onMicCaptured = delivery.onMicCaptured
        onSystemCaptured = delivery.onSystemCaptured
        onMicClean = delivery.onMicClean
        onSystem = delivery.onSystem
        onMicSpeechEvent = delivery.onMicSpeechEvent
        onSystemSpeechEvent = delivery.onSystemSpeechEvent
        usesLocalTurnDetection = localTurnDetectionSilenceDuration != nil
        if let localTurnDetectionSilenceDuration {
            // Detectors see post-AEC audio, which is always at the AEC rate, not the device rate.
            micTurnDetector = LocalTurnDetector(
                inputSampleRate: Self.aecRate,
                trailingSilenceDuration: localTurnDetectionSilenceDuration)
            systemTurnDetector = LocalTurnDetector(
                inputSampleRate: Self.aecRate,
                trailingSilenceDuration: localTurnDetectionSilenceDuration)
        } else {
            micTurnDetector = nil
            systemTurnDetector = nil
        }
    }

    func start() -> String? {
        var reason: String?
        routeQueue.sync {
            pendingRebuild?.cancel()
            pendingRebuild = nil
            rebuildIncident.reset()
            rebuildRecoveryInProgress = false
        }
        lock.lock()
        stopped = false
        // A client-commit session without detectors would stream audio but never commit a turn.
        let localTurnDetectionReady = !usesLocalTurnDetection
            || (micTurnDetector != nil && systemTurnDetector != nil)
        if #available(macOS 14.2, *), aec != nil, micDown != nil, sysDown != nil,
           localTurnDetectionReady {
            reason = buildAudioLocked()
            if reason == nil { registerRouteListenersLocked() }
        } else {
            jlog("Jarvis: one-clock capture unavailable — needs macOS 14.2+, AEC/resampler, and configured VAD")
            reason = localTurnDetectionReady
                ? "Jarvis needs macOS 14.2 or later for echo-cancelled capture."
                : "Couldn't prepare local speech detection for this transcription model."
        }
        lock.unlock()
        return reason
    }

    func stop() {
        routeQueue.sync {
            pendingRebuild?.cancel()
            pendingRebuild = nil
            rebuildIncident.stop()
            rebuildRecoveryInProgress = false
        }
        lock.lock()
        stopped = true
        removeRouteListenersLocked()
        teardownAudioLocked()
        lock.unlock()
    }

    // MARK: - Build / teardown (must hold `lock`)

    /// Self-cleaning: on failure it tears down whatever it created and returns the reason.
    private func buildAudioLocked() -> String? {
        guard #available(macOS 14.2, *) else { return "Jarvis needs macOS 14.2 or later." }
        guard let micUID = Self.defaultInputDeviceUID() else {
            jlog("Jarvis: capture — no default input device")
            return "No microphone is available. Connect an input device and press Start."
        }

        let tapDesc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted               // user keeps hearing the call
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(tapDesc, &tap) == noErr, tap != kAudioObjectUnknown else {
            jlog("Jarvis: capture — process tap creation failed (audio-capture permission?)")
            return "Couldn't capture system audio. Grant Jarvis the audio-capture permission and press Start."
        }
        tapID = tap

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Jarvis AEC",
            kAudioAggregateDeviceUIDKey: "com.jarvis.aec.capture",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDesc.uuid.uuidString, kAudioSubTapDriftCompensationKey: 1],
            ],
            // Deliberately no tap auto-start: it holds the whole aggregate, mic included, until a
            // tapped process writes audio, so a quiet session would never get an IOProc.
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg) == noErr,
              agg != kAudioObjectUnknown else {
            jlog("Jarvis: capture — aggregate device creation failed")
            teardownAudioLocked(); return "Couldn't build the audio capture device."
        }
        aggregateID = agg

        // Fail if the rate is unreadable: assuming 48 kHz would corrupt the echo model and mislabel
        // the wire rate.
        guard let deviceRate = Self.nominalSampleRate(agg) else {
            jlog("Jarvis: capture — could not read the input device's sample rate")
            teardownAudioLocked(); return "Couldn't read the audio input device's sample rate."
        }
        if abs(deviceRate - Self.aecRate) < 1 {
            micUp = nil; sysUp = nil
        } else {
            guard let mu = Resampler(fromHz: deviceRate, toHz: Self.aecRate),
                  let su = Resampler(fromHz: deviceRate, toHz: Self.aecRate) else {
                jlog("Jarvis: capture — could not build \(Int(deviceRate))→48 kHz resampler")
                teardownAudioLocked()
                return "Couldn't prepare audio resampling for this input device (\(Int(deviceRate)) Hz)."
            }
            micUp = mu; sysUp = su
        }

        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil, { [weak self] _, input, _, _, _ in
            self?.handle(input)
        }) == noErr, let proc else {
            jlog("Jarvis: capture — IOProc creation failed")
            teardownAudioLocked(); return "Couldn't start the audio capture callback."
        }
        procID = proc

        guard AudioDeviceStart(agg, proc) == noErr else {
            jlog("Jarvis: capture — device start failed")
            teardownAudioLocked(); return "Couldn't start the audio capture device."
        }
        jlog("Jarvis: capture started (mic+tap @\(Int(deviceRate)) Hz → AEC3 @48 kHz, AEC3 on).")
        return nil
    }

    private func teardownAudioLocked() {
        if let proc = procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, proc)            // drains in-flight IOProc callbacks
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggregateID = kAudioObjectUnknown; tapID = kAudioObjectUnknown
    }

    // MARK: - Route changes — rebuild against the new default devices (debounced)

    private func registerRouteListenersLocked() {
        // One physical swap can flip both default devices, so debounce to a single rebuild. The
        // listener runs on serial `routeQueue`, so the work-item bookkeeping needs no lock.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            guard self.rebuildIncident.beginOrContinue() else { return }
            if !self.rebuildRecoveryInProgress {
                self.rebuildRecoveryInProgress = true
                self.onRecoveryStateChange?(true)
            }
            self.pendingRebuild?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.rebuild() }
            self.pendingRebuild = work
            self.routeQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        routeListener = block
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, routeQueue, block)
        }
    }

    private func removeRouteListenersLocked() {
        guard let block = routeListener else { return }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, routeQueue, block)
        }
        routeListener = nil
    }

    /// Runs on `routeQueue`.
    private func rebuild() {
        var reason: String?
        var failureAction = RetryIncident.FailureAction.ignore
        lock.lock()
        if !stopped {
            teardownAudioLocked()
            // Reset detector stream state across the route splice. Teardown drained the IOProc, so
            // the serial delivery queue runs this after every pre-rebuild chunk.
            deliveryQueue.async { [micTurnDetector, systemTurnDetector] in
                micTurnDetector?.resetStreamContinuity()
                systemTurnDetector?.resetStreamContinuity()
            }
            reason = buildAudioLocked()
            if reason == nil {
                jlog("Jarvis: rebuilt capture after audio route change")
            }
        }
        lock.unlock()
        if reason == nil {
            rebuildIncident.succeeded()
            pendingRebuild = nil
            if rebuildRecoveryInProgress {
                rebuildRecoveryInProgress = false
                onRecoveryStateChange?(false)
            }
        } else {
            failureAction = rebuildIncident.failed()
        }
        guard let reason else { return }
        switch failureAction {
        case .retry(let attempt, let maximum, let delay):
            jlog("Jarvis: capture rebuild failed after route change — retrying "
                 + "\(attempt)/\(maximum)")
            let work = DispatchWorkItem { [weak self] in
                self?.rebuild()
            }
            pendingRebuild = work
            routeQueue.asyncAfter(deadline: .now() + delay, execute: work)
        case .exhausted:
            rebuildRecoveryInProgress = false
            jlog("Jarvis: capture rebuild unavailable after bounded retries")
            onUnavailable?(reason)        // notify outside the lock
        case .ignore:
            break
        }
    }

    // MARK: - The hot path

    private func handle(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count >= 2, let aec, let micDown, let sysDown else { return }
        // Buffers follow composition order, sub-devices then taps: buf0 is the mic, buf1 the tap.
        var mic = Self.monoInt16(buffers[0])
        var tap = Self.monoInt16(buffers[1])
        if let micUp { mic = micUp.convert(mic) }
        if let sysUp { tap = sysUp.convert(tap) }
        // Two copies on purpose. Transcription keeps every tap sample, padding short callbacks so
        // the server audio clock and VAD keep advancing; AEC needs an exact mic-length reference.
        let systemTap = tap
        // AEC3's reference and capture must advance by the same sample count each callback, or the
        // two framers drift apart for the rest of the session.
        let aecTap = EchoReferenceAlignment.aligned(systemTap, toFrameCount: mic.count)
        let systemTimeline = SystemAudioTimeline.preservingSamples(
            systemTap, minimumFrameCount: mic.count)

        aec.processReverse(aecTap)         // far-end reference first
        let clean = aec.process(mic)

        let micData = clean.isEmpty ? nil : Self.data(micDown.convert(clean))
        let systemData = systemTimeline.isEmpty ? nil : Self.data(sysDown.convert(systemTimeline))
        guard micData != nil || systemData != nil else { return }
        let capturedAt = Date().timeIntervalSince1970
        let micChunk: SequencedAudioChunk? = micData.map { data in
            micSequence &+= 1
            return SequencedAudioChunk(
                data: data, sequence: micSequence,
                sampleCount: data.count / MemoryLayout<Int16>.size,
                capturedAt: capturedAt)
        }
        let systemChunk: SequencedAudioChunk? = systemData.map { data in
            systemSequence &+= 1
            return SequencedAudioChunk(
                data: data, sequence: systemSequence,
                sampleCount: data.count / MemoryLayout<Int16>.size,
                capturedAt: capturedAt)
        }
        let onMicCaptured = self.onMicCaptured
        let onSystemCaptured = self.onSystemCaptured
        let onMicClean = self.onMicClean
        let onSystem = self.onSystem
        let onMicSpeechEvent = self.onMicSpeechEvent
        let onSystemSpeechEvent = self.onSystemSpeechEvent
        deliveryQueue.async { [self] in
            let micSpeechEvents = micTurnDetector?.speechEvents(
                from: clean, capturedAt: capturedAt) ?? []
            let systemSpeechEvents = systemTurnDetector?.speechEvents(
                from: systemTimeline, capturedAt: capturedAt) ?? []
            if let micChunk {
                onMicCaptured(micChunk.sequence, micChunk.sampleCount, micChunk.capturedAt)
                onMicClean(micChunk.data, micChunk.sequence, micChunk.capturedAt)
                let commitAt = micChunk.capturedAt
                    + TimeInterval(micChunk.sampleCount)
                        / TimeInterval(audioFormat.sampleRate)
                for event in Self.committing(events: micSpeechEvents, through: commitAt) {
                    onMicSpeechEvent(event, micChunk.sequence)
                }
            }
            if let systemChunk {
                onSystemCaptured(systemChunk.sequence, systemChunk.sampleCount, systemChunk.capturedAt)
                onSystem(systemChunk.data, systemChunk.sequence, systemChunk.capturedAt)
                let commitAt = systemChunk.capturedAt
                    + TimeInterval(systemChunk.sampleCount)
                        / TimeInterval(audioFormat.sampleRate)
                for event in Self.committing(events: systemSpeechEvents, through: commitAt) {
                    onSystemSpeechEvent(event, systemChunk.sequence)
                }
            }
        }
    }


    /// Commits through the whole delivered chunk containing the endpoint, so the wire FIFO and the
    /// capture boundary stay identical even when a resampler emits a small tail.
    private static func committing(
        events: [SpeechEndpointDetector.Event],
        through commitAt: TimeInterval
    ) -> [LocalSpeechEvent] {
        events.map { event in
            switch event {
            case .started(let startedAt):
                return .started(at: startedAt)
            case .ended(let startedAt, _):
                return .ended(startedAt: startedAt, commitAt: commitAt)
            }
        }
    }

    // MARK: - Core Audio / format helpers

    private static func monoInt16(_ b: AudioBuffer) -> [Int16] {
        let total = Int(b.mDataByteSize) / MemoryLayout<Float32>.size
        guard total > 0, let raw = b.mData else { return [] }
        let floats = Array(UnsafeBufferPointer(start: raw.bindMemory(to: Float.self, capacity: total), count: total))
        return AudioDownmix.monoInt16(floats, channels: Int(b.mNumberChannels))
    }

    private static func data(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func nominalSampleRate(_ dev: AudioObjectID) -> Double? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    private static func defaultInputDeviceUID() -> String? {
        var devID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr,
              devID != kAudioObjectUnknown else { return nil }
        // kAudioDevicePropertyDeviceUID returns a +1-retained CFString the caller must release.
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(devID, &uidAddr, 0, nil, &uidSize, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
