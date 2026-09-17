import CoreAudio
import JarvisCore

enum InputDeviceProximity {
    static func current() -> MicProximity {
        guard let transport = defaultInputTransportType() else { return .unknown }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeUSB:
            return .near    // headset, earbuds, AirPods, USB close mic
        case kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeAirPlay:
            return .far     // laptop, monitor, dock, remote: across the desk or further
        default:
            return .unknown
        }
    }

    private static func defaultInputTransportType() -> UInt32? {
        var devID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var devAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devAddr, 0, nil,
                                         &size, &devID) == noErr, devID != kAudioObjectUnknown
        else { return nil }

        var transport = UInt32(0)
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(devID, &tAddr, 0, nil, &tSize, &transport) == noErr
        else { return nil }
        return transport
    }
}
