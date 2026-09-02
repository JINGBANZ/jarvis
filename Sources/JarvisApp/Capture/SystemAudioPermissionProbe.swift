import Foundation
import CoreAudio
import AVFoundation
import JarvisCore

/// Requests, and proves, the System Audio Recording grant that Core Audio process taps need.
///
/// Both halves are awkward. macOS publishes no API to request the grant, so the only way to raise
/// the prompt is to build a tap-backed device and start it. And TCC enforces this one *silently*:
/// with the grant refused, every call still returns `noErr`, the tap still reports a 48 kHz format,
/// the device still starts, and IOProc callbacks still arrive. The single observable difference is
/// that every sample is a bit-exact zero. Measured on macOS 26: 117 callbacks with a peak of 0.25
/// when allowed, 116 callbacks with a peak of 0.0 when denied.
///
/// So the probe proves the grant by making a sound and listening for it. To keep that invisible, the
/// tap covers **only Jarvis's own process** rather than the system mix, and mutes it: nothing the
/// user is playing is tapped, nothing they are listening to is muted, and Jarvis's own half-second
/// tone never reaches the speakers. Hearing it back is proof; digital silence is proof of refusal.
enum SystemAudioPermissionProbe {
    /// Plays a muted tone into a tap of Jarvis's own audio and reports whether it came back. On a
    /// fresh install this is what raises "Jarvis wants to record this computer's audio", and the
    /// call blocks until the user answers. Afterwards macOS answers for them, so it doubles as the
    /// check that no public API provides.
    ///
    /// `nil` means the probe could not run at all — no output device, a tap or device that would
    /// not build, a tone that would not play. That is not a refusal, and callers must not record it
    /// as one: a Bluetooth device mid-transition would otherwise overwrite a proved grant.
    static func requestAccess() -> Bool? {
        guard #available(macOS 14.2, *) else { return nil }
        guard let processObject = ownProcessObject() else {
            jlog("Jarvis: system-audio probe — Core Audio doesn't know this process")
            return nil
        }
        guard let outputUID = defaultOutputDeviceUID() else {
            jlog("Jarvis: system-audio probe — no default output device to clock the tap")
            return nil
        }

        let description = CATapDescription(monoMixdownOfProcesses: [processObject])
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.muted   // the probe tone is never heard
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr,
              tap != kAudioObjectUnknown else {
            jlog("Jarvis: system-audio probe — process tap creation failed")
            return nil
        }
        defer { AudioHardwareDestroyProcessTap(tap) }

        // A unique UID per probe: reusing one leaves a stale private device behind that makes the
        // next probe fail to start for reasons that have nothing to do with permission.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Jarvis Permission Probe",
            kAudioAggregateDeviceUIDKey: "com.jarvis.permission.probe.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            // Clock only. The output device carries no capture of its own, and the tap above is
            // scoped to this process, so no other application's audio is in reach.
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString],
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggregate) == noErr,
              aggregate != kAudioObjectUnknown else {
            jlog("Jarvis: system-audio probe — aggregate device creation failed")
            return nil
        }
        defer { AudioHardwareDestroyAggregateDevice(aggregate) }

        // Written on the realtime IOProc thread and read only after `AudioDeviceStop`, which drains
        // in-flight callbacks — so no lock is taken on the audio thread.
        let heard = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        heard.initialize(to: false)
        defer { heard.deinitialize(count: 1); heard.deallocate() }

        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil, { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: input))
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for index in 0..<count where samples[index] != 0 {
                    heard.pointee = true
                    return
                }
            }
        }) == noErr, let proc else {
            jlog("Jarvis: system-audio probe — IOProc creation failed")
            return nil
        }
        defer { AudioDeviceDestroyIOProcID(aggregate, proc) }

        guard AudioDeviceStart(aggregate, proc) == noErr else {
            jlog("Jarvis: system-audio probe — device start failed")
            return nil
        }
        // Not dead code: any return below leaves the device running, and the cleanup that follows
        // destroys the IOProc and frees `heard` while callbacks could still be writing through it.
        // The explicit stop before the read is the one that orders the read; this one covers exits.
        defer { AudioDeviceStop(aggregate, proc) }

        guard let engine = playProbeTone() else { return nil }
        defer { engine.stop() }
        // Deliberately not polling `heard` while the tone plays: that would read the flag on this
        // thread while the IOProc writes it. Waiting the whole window and reading once after
        // `AudioDeviceStop` costs a fixed second and needs no synchronization on the audio thread.
        Thread.sleep(forTimeInterval: Self.deadline)
        // `AVAudioEngine` stops itself on a configuration change, so a device arriving mid-probe
        // (AirPods connecting, say) silences the tone. Read this before the stop, which would set it
        // false anyway. No tone means a probe that could not run, not a grant that was refused.
        let tonePlayedThroughout = engine.isRunning
        AudioDeviceStop(aggregate, proc)
        guard tonePlayedThroughout else {
            jlog("Jarvis: system-audio probe — the audio engine stopped before the tone finished")
            return nil
        }

        let granted = heard.pointee
        jlog("Jarvis: system-audio permission \(granted ? "granted" : "denied — the tone played but came back as digital silence")")
        return granted
    }

    /// How long to listen. Comfortably longer than the half-second tone, since the probe always
    /// waits the whole window rather than watching the flag as the IOProc writes it.
    private static let deadline: TimeInterval = 1.2

    /// Half a second of a quiet 440 Hz tone, played by Jarvis so Jarvis's own tap can hear it. The
    /// engine is returned so the caller keeps it alive for the length of the probe.
    private static func playProbeTone() -> AVAudioEngine? {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            return nil
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let frames = AVAudioFrameCount(24_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let samples = channels[channel]
            for frame in 0..<Int(frames) {
                samples[frame] = 0.25 * sinf(2 * .pi * 440 * Float(frame) / 48_000)
            }
        }

        do {
            try engine.start()
        } catch {
            jlog("Jarvis: system-audio probe — couldn't play the probe tone: \(error)")
            return nil
        }
        player.scheduleBuffer(buffer, at: nil, options: [])
        player.play()
        return engine
    }

    /// This process as Core Audio sees it, which is what a per-process tap takes.
    private static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object) == noErr,
              object != kAudioObjectUnknown else { return nil }
        return object
    }

    /// The device the tap is clocked by. Mirrors `AggregateEchoCapture`'s input-side lookup; the
    /// probe stays self-contained so it can run before any capture object exists.
    private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        // kAudioDevicePropertyDeviceUID returns a +1-retained CFString the caller must release.
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
