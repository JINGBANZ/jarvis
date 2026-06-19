import Foundation
import CoreAudio
import JarvisCore

/// One-clock capture + echo cancellation. Builds a single PRIVATE Core Audio aggregate device =
/// built-in mic (clock master) + system-output process tap (drift-compensated), so ONE IOProc
/// delivers mic + reference synchronized at 48 kHz — the single-clock case AEC3 needs (proven live:
/// 30–50 dB cancellation). Inside that callback it runs WebRTC AEC3 (reference = tap, near = mic),
/// then downsamples to 24 kHz: cleaned mic → `onMicClean` ("me" socket), raw tap → `onSystem` ("them"
/// socket). Replaces the separate AVAudioEngine mic + ScreenCaptureKit capture. macOS 14.2+.
///
/// The tap targets the output device and the aggregate pins a mic sub-device, both chosen at build
/// time — so when the audio route changes mid-session (headphones in/out, AirPods, mic swapped) we
/// rebuild against the new default devices (see the route listeners). AEC3 stays on across all routes:
/// it's near-passthrough on headphones (no echo to cancel) and we deliberately don't try to "detect
/// headphones and bypass", because that detection is unreliable (a Bluetooth *speaker* looks like
/// headphones) and a wrong bypass would let the echo back in.
///
/// `@unchecked Sendable`: audio state is touched only by the single IOProc thread; lifecycle
/// (build/teardown/rebuild/stop) is serialized by `lock`. The IOProc never takes `lock`, and teardown
/// calls `AudioDeviceStop` (which drains in-flight callbacks) before destroying anything.
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
    private var stopped = false

    init(onMicClean: @escaping @Sendable (Data) -> Void, onSystem: @escaping @Sendable (Data) -> Void) {
        self.onMicClean = onMicClean
        self.onSystem = onSystem
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard #available(macOS 14.2, *) else { fail("needs macOS 14.2+"); return }
        guard aec != nil, micDown != nil, sysDown != nil else { fail("canceller/resampler unavailable"); return }
        guard buildAudioLocked() else { return }
        registerRouteListenersLocked()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        removeRouteListenersLocked()
        teardownAudioLocked()
    }

    // MARK: - Build / teardown (must hold `lock`)

    @discardableResult
    private func buildAudioLocked() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        guard let micUID = Self.defaultInputDeviceUID() else { fail("no default input device"); return false }

        let tapDesc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted               // user keeps hearing the call
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(tapDesc, &tap) == noErr, tap != kAudioObjectUnknown else {
            fail("process tap creation failed (audio-capture permission?)"); return false
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
              agg != kAudioObjectUnknown else { fail("aggregate device creation failed"); return false }
        aggregateID = agg

        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil, { [weak self] _, input, _, _, _ in
            self?.handle(input)
        }) == noErr, let proc else { fail("IOProc creation failed"); return false }
        procID = proc

        guard AudioDeviceStart(agg, proc) == noErr else { fail("device start failed"); return false }
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

    // MARK: - Route changes — rebuild against the new default devices

    private func registerRouteListenersLocked() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuild() }
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
    /// on `routeQueue` (serial), so rebuilds don't overlap; the `stopped` guard makes a late change a no-op.
    private func rebuild() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        teardownAudioLocked()
        if buildAudioLocked() {
            jlog("Jarvis: rebuilt capture after audio route change")
        } else {
            jlog("Jarvis: capture rebuild failed after route change")
            onUnavailable?()
        }
    }

    // MARK: - The hot path

    private func handle(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count >= 2, let aec, let micDown, let sysDown else { return }
        // Composition order = sub-devices (mic) then taps; confirmed live: buf0=mic, buf1=tap.
        let mic = Self.monoInt16(buffers[0])
        let tap = Self.monoInt16(buffers[1])

        aec.processReverse(tap)            // far-end reference FIRST
        let clean = aec.process(mic)       // near-end, echo removed

        if !clean.isEmpty { onMicClean(Self.data(micDown.convert(clean))) }
        if !tap.isEmpty { onSystem(Self.data(sysDown.convert(tap))) }
    }

    private func fail(_ why: String) {
        jlog("Jarvis: one-clock capture unavailable — \(why)")
        onUnavailable?()
    }

    // MARK: - Core Audio / format helpers

    /// One AudioBuffer of Float32 (1 or 2 interleaved channels) → mono PCM16.
    private static func monoInt16(_ b: AudioBuffer) -> [Int16] {
        let total = Int(b.mDataByteSize) / MemoryLayout<Float32>.size
        guard total > 0, let raw = b.mData else { return [] }
        let f = raw.bindMemory(to: Float32.self, capacity: total)
        let ch = max(1, Int(b.mNumberChannels))
        let frames = total / ch
        var out = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            var acc: Float = 0
            for c in 0..<ch { acc += f[i * ch + c] }
            let v = max(-1, min(1, acc / Float(ch))) * 32767
            out[i] = Int16(v)
        }
        return out
    }

    private static func data(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func defaultInputDeviceUID() -> String? {
        var devID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr,
              devID != kAudioObjectUnknown else { return nil }
        var uid = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(devID, &uidAddr, 0, nil, &uidSize, $0)
        }
        return status == noErr ? (uid as String) : nil
    }
}
