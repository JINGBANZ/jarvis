import Foundation
import CoreAudio
import JarvisCore

/// Requests — and in the same call, checks — the System Audio Recording grant that Core Audio
/// process taps need.
///
/// macOS publishes no API for either half. `AudioHardwareCreateProcessTap` succeeds without the
/// grant, and the prompt only appears once a tap-backed device actually starts, so the only way to
/// ask is to build one and start it. This probe builds the smallest device that will do: a private
/// aggregate whose only member is the tap, clocked by the default *output* device. No microphone
/// sub-device, so probing can't light the input-in-use indicator, and its IOProc has no body —
/// nothing is read, buffered, or written.
///
/// `AggregateEchoCapture` builds the real capture device and stays untouched by this: the probe
/// runs at launch, owns nothing, and leaves no device behind.
enum SystemAudioPermissionProbe {
    /// Starts and immediately stops a throwaway tap. On a fresh install this is what makes macOS
    /// show "Jarvis wants to record this computer's audio", and the call blocks until the user
    /// answers. Afterwards macOS answers for them without prompting, so this doubles as the check.
    static func requestAccess() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        guard let outputUID = defaultOutputDeviceUID() else {
            jlog("Jarvis: system-audio probe — no default output device to clock the tap")
            return false
        }

        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted        // never interrupt what the user is hearing
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(tapDescription, &tap) == noErr,
              tap != kAudioObjectUnknown else {
            jlog("Jarvis: system-audio probe — process tap creation failed")
            return false
        }
        defer { AudioHardwareDestroyProcessTap(tap) }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Jarvis Permission Probe",
            kAudioAggregateDeviceUIDKey: "com.jarvis.permission.probe",
            kAudioAggregateDeviceIsPrivateKey: true,
            // Clock only: an aggregate needs a main sub-device, and the output device is the one
            // member that carries no capture of its own.
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDescription.uuid.uuidString],
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate) == noErr,
              aggregate != kAudioObjectUnknown else {
            jlog("Jarvis: system-audio probe — aggregate device creation failed")
            return false
        }
        defer { AudioHardwareDestroyAggregateDevice(aggregate) }

        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil, { _, _, _, _, _ in }) == noErr,
              let proc else {
            jlog("Jarvis: system-audio probe — IOProc creation failed")
            return false
        }
        defer { AudioDeviceDestroyIOProcID(aggregate, proc) }

        guard AudioDeviceStart(aggregate, proc) == noErr else {
            jlog("Jarvis: system-audio permission denied — enable System Audio Recording in "
                 + "System Settings › Privacy & Security")
            return false
        }
        AudioDeviceStop(aggregate, proc)
        jlog("Jarvis: system-audio permission granted")
        return true
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
