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
/// callbacks (`onUnavailable`) are invoked OUTSIDE the lock.
final class AggregateEchoCapture: @unchecked Sendable {
    private let onMicClean: @Sendable (Data) -> Void
    private let onSystem: @Sendable (Data) -> Void
    /// Fired if the device can't be built/started — the caller decides how to degrade.
    var onUnavailable: (@Sendable () -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    private let aec = WebRTCEchoCanceller()          // adaptive; re-converges across route rebuilds
    private let micDown = Resampler(fromHz: 48_000, toHz: 24_000)   // cleaned mic → 24 kHz wire
    private let sysDown = Resampler(fromHz: 48_000, toHz: 24_000)   // tap → 24 kHz wire

    private let lock = NSLock()
    private let routeQueue = DispatchQueue(label: "jarvis.aec.routes")
    private var routeListener: AudioObjectPropertyListenerBlock?
    private var pendingRebuild: DispatchWorkItem?
    private var stopped = false

    init(onMicClean: @escaping @Sendable (Data) -> Void, onSystem: @escaping @Sendable (Data) -> Void) {
        self.onMicClean = onMicClean
        self.onSystem = onSystem
    }

    func start() {
        var built = false
        lock.lock()
        if #available(macOS 14.2, *), aec != nil, micDown != nil, sysDown != nil {
            built = buildAudioLocked()
            if built { registerRouteListenersLocked() }
        } else {
            jlog("Jarvis: one-clock capture unavailable — needs macOS 14.2+ and AEC/resampler")
        }
        lock.unlock()
        if !built { onUnavailable?() }      // notify outside the lock
    }

    func stop() {
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
    private func buildAudioLocked() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        guard let micUID = Self.defaultInputDeviceUID() else {
            jlog("Jarvis: capture — no default input device"); return false
        }

        let tapDesc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted               // user keeps hearing the call
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(tapDesc, &tap) == noErr, tap != kAudioObjectUnknown else {
            jlog("Jarvis: capture — process tap creation failed (audio-capture permission?)"); return false
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
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg) == noErr,
              agg != kAudioObjectUnknown else {
            jlog("Jarvis: capture — aggregate device creation failed"); teardownAudioLocked(); return false
        }
        aggregateID = agg

        // AEC3, the 480-sample (10 ms) framing, and the 48→24 resamplers all assume 48 kHz. The
        // aggregate otherwise inherits the mic's rate (could be 44.1 kHz), which would corrupt the
        // echo model and mislabel the wire rate to the transcriber — so pin it and verify.
        guard Self.setNominalSampleRate(agg, 48_000) else {
            jlog("Jarvis: capture — could not pin aggregate to 48 kHz"); teardownAudioLocked(); return false
        }

        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil, { [weak self] _, input, _, _, _ in
            self?.handle(input)
        }) == noErr, let proc else {
            jlog("Jarvis: capture — IOProc creation failed"); teardownAudioLocked(); return false
        }
        procID = proc

        guard AudioDeviceStart(agg, proc) == noErr else {
            jlog("Jarvis: capture — device start failed"); teardownAudioLocked(); return false
        }
        jlog("Jarvis: capture started (one-clock mic + system tap @48 kHz, AEC3 on).")
        return true
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
        var failed = false
        lock.lock()
        if !stopped {
            teardownAudioLocked()
            if buildAudioLocked() {
                jlog("Jarvis: rebuilt capture after audio route change")
            } else {
                failed = true
            }
        }
        lock.unlock()
        if failed {
            jlog("Jarvis: capture rebuild failed after route change")
            onUnavailable?()        // notify outside the lock
        }
    }

    // MARK: - The hot path

    private func handle(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count >= 2, let aec, let micDown, let sysDown else { return }
        // Composition order = sub-devices (mic) then taps; confirmed live: buf0=mic, buf1=tap.
        let mic = Self.monoInt16(buffers[0])
        var tap = Self.monoInt16(buffers[1])
        // Keep far and near in lockstep: AEC3's reference and capture must advance by the SAME sample
        // count each callback, or the two framers drift apart for the rest of the session. The tap can
        // legitimately deliver a short/empty buffer (silence), so pad/truncate it to the mic's count.
        if tap.count != mic.count {
            if tap.count < mic.count { tap.append(contentsOf: repeatElement(0, count: mic.count - tap.count)) }
            else { tap.removeLast(tap.count - mic.count) }
        }

        aec.processReverse(tap)            // far-end reference FIRST
        let clean = aec.process(mic)       // near-end, echo removed

        if !clean.isEmpty { onMicClean(Self.data(micDown.convert(clean))) }
        if !tap.isEmpty { onSystem(Self.data(sysDown.convert(tap))) }
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

    /// Set a device's nominal sample rate and confirm it took (within 1 Hz). Returns false on failure.
    private static func setNominalSampleRate(_ dev: AudioObjectID, _ rate: Double) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var wanted = rate
        guard AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &wanted) == noErr
        else { return false }
        var actual = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &actual) == noErr else { return false }
        return abs(actual - rate) < 1
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
