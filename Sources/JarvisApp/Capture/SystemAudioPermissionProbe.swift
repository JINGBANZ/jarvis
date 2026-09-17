import Foundation
import CoreAudio
import AVFoundation
import JarvisCore

/// Design: wiki/architecture.md#permissions
///
/// TCC enforces this grant silently: a refused tap still starts and delivers callbacks, but every
/// sample is zero. So the probe plays a muted tone into a tap of Jarvis's own process only.
enum SystemAudioPermissionProbe {
    /// Blocks until the user answers the first-run prompt. `nil` means the probe could not run,
    /// which is not a refusal and must not be recorded as one.
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

        // Unique UID per probe: a reused one can leave a stale device that fails the next start.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Jarvis Permission Probe",
            kAudioAggregateDeviceUIDKey: "com.jarvis.permission.probe.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            // Clock only. The tap is scoped to this process, so no other app's audio is in reach.
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

        // Written on the IOProc thread and read only after `AudioDeviceStop` drains callbacks, so
        // no lock is taken on the audio thread.
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
        // Not dead code: an early return would free `heard` while callbacks still write it.
        defer { AudioDeviceStop(aggregate, proc) }

        guard let engine = playProbeTone() else { return nil }
        defer { engine.stop() }
        // Don't poll `heard` while the tone plays: that would race the IOProc writing it.
        Thread.sleep(forTimeInterval: Self.deadline)
        // `AVAudioEngine` stops itself on a configuration change, such as AirPods connecting. Read
        // this before the stop; a silenced tone means the probe could not run, not a refusal.
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

    /// Comfortably longer than the half-second tone, since the probe always waits the whole window.
    private static let deadline: TimeInterval = 1.2

    /// The caller must keep the returned engine alive for the length of the probe.
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
