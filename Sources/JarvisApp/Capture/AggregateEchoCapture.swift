import Foundation
import CoreAudio
import JarvisCore

/// One-clock capture + echo cancellation. Builds a single PRIVATE Core Audio aggregate device =
/// built-in mic (clock master) + system-output process tap (drift-compensated), so ONE IOProc
/// delivers mic + reference synchronized at 48 kHz — the single-clock case AEC3 needs (proven live:
/// 30–50 dB cancellation, works in Zoom on speakers). Inside that callback it runs WebRTC AEC3
/// (reference = tap, near = mic), then downsamples to 24 kHz: cleaned mic → `onMicClean` ("me"
/// socket), raw tap → `onSystem` ("them" socket). Replaces the separate AVAudioEngine mic +
/// ScreenCaptureKit capture. macOS 14.2+.
///
/// The tap targets the output device and the aggregate pins a mic sub-device, both chosen at build
/// time — so when the audio route changes mid-session (headphones in/out, AirPods, mic swapped) we
/// rebuild against the new default devices (route listeners, debounced). AEC3 stays on across all
/// routes: it's near-passthrough on headphones (no echo to cancel) and we deliberately don't try to
/// "detect headphones and bypass" — that detection is unreliable (a Bluetooth *speaker* looks like
/// headphones) and a wrong bypass would let the echo back in.
///
/// `@unchecked Sendable`: audio state is touched only by the single IOProc thread; lifecycle
/// (build/teardown/rebuild/stop) is serialized by `lock`. The IOProc never takes `lock`, and teardown
/// calls `AudioDeviceStop` (which drains in-flight callbacks) before destroying anything. Client
/// audio delivery is moved onto one serial queue so encoding/network work cannot stall Core Audio;
/// `onUnavailable` is invoked outside the lock.
final class AggregateEchoCapture: @unchecked Sendable {
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
    /// Fired if the device can't be built/started mid-session (route-change rebuild) — the caller
    /// decides how to surface it. Carries a human-readable reason.
    var onUnavailable: (@Sendable (String) -> Void)?
    /// True while the capture owns a bounded route-rebuild incident, false after it successfully
    /// rebuilds. Exhaustion is reported through `onUnavailable` instead.
    var onRecoveryStateChange: (@Sendable (Bool) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    private let aec = WebRTCEchoCanceller()          // adaptive; re-converges across route rebuilds
    private let micDown = Resampler(
        fromHz: 48_000,
        toHz: Double(TranscriptionAudioFormat.pcm16Mono.sampleRate))
    private let sysDown = Resampler(
        fromHz: 48_000,
        toHz: Double(TranscriptionAudioFormat.pcm16Mono.sampleRate))
    private let usesLocalTurnDetection: Bool
    private let micVoiceActivityDetector: WebRTCVoiceActivityDetector?
    private let systemVoiceActivityDetector: WebRTCVoiceActivityDetector?
    /// IOProc-only value state. WebRTC supplies frame decisions; Core owns the endpoint policy.
    private var micEndpointDetector: SpeechEndpointDetector?
    private var systemEndpointDetector: SpeechEndpointDetector?
    /// Device-native → 48 kHz, rebuilt per `buildAudioLocked` from the aggregate's actual rate. `nil`
    /// when the device is already 48 kHz (then mic/tap feed AEC directly — the built-in path, unchanged).
    /// Touched only by the IOProc thread (read in `handle`) and by build/rebuild under `lock` while the
    /// device is stopped — same discipline as `procID`/`aggregateID`, covered by `@unchecked Sendable`.
    private var micUp: Resampler?
    private var sysUp: Resampler?

    private static let aecRate = 48_000.0

    private let lock = NSLock()
    private let routeQueue = DispatchQueue(label: "jarvis.aec.routes")
    /// Device routes often disappear briefly while macOS switches hardware. Preserve the live
    /// conversation through that interval; only a full bounded retry budget proves capture unusable.
    private var rebuildIncident = RetryIncident(schedule: RetrySchedule(
        maximumRetries: 6, initialDelay: 0.5, maximumDelay: 5))
    /// Confined to `routeQueue`; keeps repeated device notifications inside one recovery interval.
    private var rebuildRecoveryInProgress = false
    /// Both speaker streams share one queue to preserve the IOProc's callback order (cleaned mic,
    /// then untouched system tap) without doing Realtime encoding/sends on the audio thread.
    private let deliveryQueue = DispatchQueue(label: "jarvis.aec.delivery", qos: .userInitiated)
    private var routeListener: AudioObjectPropertyListenerBlock?
    private var pendingRebuild: DispatchWorkItem?
    private var stopped = false
    /// Assigned on the single IOProc thread and preserved across route rebuilds. A gap at any later
    /// boundary is therefore diagnosable without retaining the audio itself.
    private var micSequence: UInt64 = 0
    private var systemSequence: UInt64 = 0

    init(onMicCaptured: @escaping @Sendable (UInt64, Int, TimeInterval) -> Void,
         onSystemCaptured: @escaping @Sendable (UInt64, Int, TimeInterval) -> Void,
         onMicClean: @escaping @Sendable (Data, UInt64, TimeInterval) -> Void,
         onSystem: @escaping @Sendable (Data, UInt64, TimeInterval) -> Void,
         localTurnDetectionSilenceDuration: TimeInterval?,
         onMicSpeechEvent: @escaping @Sendable (LocalSpeechEvent, UInt64) -> Void,
         onSystemSpeechEvent: @escaping @Sendable (LocalSpeechEvent, UInt64) -> Void) {
        self.onMicCaptured = onMicCaptured
        self.onSystemCaptured = onSystemCaptured
        self.onMicClean = onMicClean
        self.onSystem = onSystem
        self.onMicSpeechEvent = onMicSpeechEvent
        self.onSystemSpeechEvent = onSystemSpeechEvent
        usesLocalTurnDetection = localTurnDetectionSilenceDuration != nil
        if let localTurnDetectionSilenceDuration {
            micVoiceActivityDetector = WebRTCVoiceActivityDetector()
            systemVoiceActivityDetector = WebRTCVoiceActivityDetector()
            micEndpointDetector = SpeechEndpointDetector(
                trailingSilenceDuration: localTurnDetectionSilenceDuration)
            systemEndpointDetector = SpeechEndpointDetector(
                trailingSilenceDuration: localTurnDetectionSilenceDuration)
        } else {
            micVoiceActivityDetector = nil
            systemVoiceActivityDetector = nil
            micEndpointDetector = nil
            systemEndpointDetector = nil
        }
    }

    /// Build + start capture. Returns `nil` on success, or a human-readable reason on failure (the
    /// caller surfaces it via `ErrorReporter`). Mid-session rebuild failures go through `onUnavailable`.
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
        let localTurnDetectionReady = !usesLocalTurnDetection
            || (micVoiceActivityDetector != nil && systemVoiceActivityDetector != nil)
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

    /// Builds tap + aggregate + IOProc. Self-cleaning: on any failure it tears down whatever it
    /// already created and returns false, so it never leaves partial state. Logs the failure; the
    /// caller notifies `onUnavailable` outside the lock.
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
            // Deliberately omit tap auto-start. Enabling it waits for a tapped process to begin
            // writing system audio before starting the entire aggregate, including the microphone.
            // Quiet sessions would otherwise arm successfully without ever delivering an IOProc.
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg) == noErr,
              agg != kAudioObjectUnknown else {
            jlog("Jarvis: capture — aggregate device creation failed")
            teardownAudioLocked(); return "Couldn't build the audio capture device."
        }
        aggregateID = agg

        // Don't fight the device's rate — read it. AEC3, the 480-sample framing, and the 48→24 resamplers
        // all run at 48 kHz, so resample the device-native rate up to 48 kHz before AEC (mic+tap come off
        // ONE clock, so they stay sample-synced; the far/near lockstep in `handle` absorbs converter slack).
        // If we can't read the rate, fail loud — assuming 48 kHz when it isn't would corrupt the echo
        // model and mislabel the wire rate (the exact thing the old pin guarded).
        guard let deviceRate = Self.nominalSampleRate(agg) else {
            jlog("Jarvis: capture — could not read the input device's sample rate")
            teardownAudioLocked(); return "Couldn't read the audio input device's sample rate."
        }
        if abs(deviceRate - Self.aecRate) < 1 {
            micUp = nil; sysUp = nil                         // already 48 kHz — feed AEC directly
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
        // Coalesce: a single physical swap can flip both default-in and default-out (two callbacks);
        // debounce so we rebuild once. The listener runs on routeQueue (serial), so the work-item
        // bookkeeping needs no extra locking.
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

    /// Default input/output device changed — rebuild the tap + aggregate against the new route. Runs
    /// on `routeQueue` (serial, debounced); the `stopped` guard makes a late change a no-op.
    private func rebuild() {
        var reason: String?
        var failureAction = RetryIncident.FailureAction.ignore
        lock.lock()
        if !stopped {
            teardownAudioLocked()
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
        // Composition order = sub-devices (mic) then taps; confirmed live: buf0=mic, buf1=tap.
        var mic = Self.monoInt16(buffers[0])
        var tap = Self.monoInt16(buffers[1])
        // Resample device-native → 48 kHz for AEC (no-ops to today's path when the device is already
        // 48 kHz and the up-resamplers are nil).
        if let micUp { mic = micUp.convert(mic) }
        if let sysUp { tap = sysUp.convert(tap) }
        // Keep two purpose-specific copies. Transcription preserves every real tap sample and pads a
        // short/empty callback to the mic duration so the server audio clock and trailing-silence VAD
        // keep advancing. AEC needs an exact mic-length reference and may therefore also truncate.
        let systemTap = tap
        // Keep far and near in lockstep AT THE AEC RATE: AEC3's reference and capture must advance by the
        // SAME sample count each callback, or the two framers drift apart for the rest of the session. The
        // tap can legitimately be short/empty (silence), and the two converters can emit a sample or two
        // apart — so pad/truncate the tap to the mic's count after resampling.
        let aecTap = EchoReferenceAlignment.aligned(systemTap, toFrameCount: mic.count)
        let systemTimeline = SystemAudioTimeline.preservingSamples(
            systemTap, minimumFrameCount: mic.count)

        aec.processReverse(aecTap)         // far-end reference FIRST
        let clean = aec.process(mic)       // near-end, echo removed

        let micData = clean.isEmpty ? nil : Self.data(micDown.convert(clean))
        let systemData = systemTimeline.isEmpty ? nil : Self.data(sysDown.convert(systemTimeline))
        guard micData != nil || systemData != nil else { return }
        let capturedAt = Date().timeIntervalSince1970
        let micSpeechEvents = localMicSpeechEvents(clean, capturedAt: capturedAt)
        let systemSpeechEvents = localSystemSpeechEvents(systemTimeline, capturedAt: capturedAt)
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
        deliveryQueue.async {
            if let micChunk {
                onMicCaptured(micChunk.sequence, micChunk.sampleCount, micChunk.capturedAt)
                onMicClean(micChunk.data, micChunk.sequence, micChunk.capturedAt)
                let commitAt = micChunk.capturedAt
                    + TimeInterval(micChunk.sampleCount)
                        / TimeInterval(TranscriptionAudioFormat.pcm16Mono.sampleRate)
                for event in Self.committing(events: micSpeechEvents, through: commitAt) {
                    onMicSpeechEvent(event, micChunk.sequence)
                }
            }
            if let systemChunk {
                onSystemCaptured(systemChunk.sequence, systemChunk.sampleCount, systemChunk.capturedAt)
                onSystem(systemChunk.data, systemChunk.sequence, systemChunk.capturedAt)
                let commitAt = systemChunk.capturedAt
                    + TimeInterval(systemChunk.sampleCount)
                        / TimeInterval(TranscriptionAudioFormat.pcm16Mono.sampleRate)
                for event in Self.committing(events: systemSpeechEvents, through: commitAt) {
                    onSystemSpeechEvent(event, systemChunk.sequence)
                }
            }
        }
    }

    private func localMicSpeechEvents(
        _ samples: [Int16],
        capturedAt: TimeInterval
    ) -> [SpeechEndpointDetector.Event] {
        guard let micVoiceActivityDetector, var detector = micEndpointDetector else { return [] }
        let events = Self.endpointEvents(
            decisions: micVoiceActivityDetector.classify(samples),
            detector: &detector,
            capturedAt: capturedAt)
        micEndpointDetector = detector
        return events
    }

    private func localSystemSpeechEvents(
        _ samples: [Int16],
        capturedAt: TimeInterval
    ) -> [SpeechEndpointDetector.Event] {
        guard let systemVoiceActivityDetector, var detector = systemEndpointDetector else { return [] }
        let events = Self.endpointEvents(
            decisions: systemVoiceActivityDetector.classify(samples),
            detector: &detector,
            capturedAt: capturedAt)
        systemEndpointDetector = detector
        return events
    }

    private static func endpointEvents(
        decisions: [Bool],
        detector: inout SpeechEndpointDetector,
        capturedAt: TimeInterval
    ) -> [SpeechEndpointDetector.Event] {
        decisions.enumerated().compactMap { index, isSpeech in
            detector.observe(
                isSpeech: isSpeech,
                frameStartedAt: capturedAt + TimeInterval(index) / 100)
        }
    }

    /// Commit through the whole delivered 24 kHz chunk containing the endpoint. This keeps the wire
    /// FIFO and capture boundary identical even when a resampler emits a small converter tail.
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

    /// One AudioBuffer of interleaved Float32 → mono PCM16 (downmix logic is in `JarvisCore`).
    private static func monoInt16(_ b: AudioBuffer) -> [Int16] {
        let total = Int(b.mDataByteSize) / MemoryLayout<Float32>.size
        guard total > 0, let raw = b.mData else { return [] }
        let floats = Array(UnsafeBufferPointer(start: raw.bindMemory(to: Float.self, capacity: total), count: total))
        return AudioDownmix.monoInt16(floats, channels: Int(b.mNumberChannels))
    }

    private static func data(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Read a device's current nominal sample rate. Returns nil if it can't be read.
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
