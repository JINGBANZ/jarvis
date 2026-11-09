import CoreAudio
import Foundation

struct ReleaseAudioDevices {
    private let microphone: AudioObjectID
    private let output: AudioObjectID
    private let previousInput: AudioObjectID
    private let previousOutput: AudioObjectID

    init() throws {
        previousInput = try Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        previousOutput = try Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try Self.check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        guard size > 0, size % 4 == 0, size <= 4096 else { throw Failure.invalidDevices }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        try devices.withUnsafeMutableBytes {
            try Self.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!))
        }
        var inputs: [AudioObjectID] = [], outputs: [AudioObjectID] = []
        for device in devices {
            var uid: Unmanaged<CFString>?
            var bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            address.mSelector = kAudioDevicePropertyDeviceUID
            try Self.check(AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &uid))
            guard let uid else { throw Failure.invalidDevices }
            let identifier = uid.takeRetainedValue() as String
            if identifier == "BlackHole16ch_UID" { inputs.append(device) }
            if identifier == "BlackHole2ch_UID" { outputs.append(device) }
        }
        guard inputs.count == 1, outputs.count == 1,
              try Self.channels(inputs[0], scope: kAudioObjectPropertyScopeInput) == 16,
              try Self.channels(outputs[0], scope: kAudioObjectPropertyScopeOutput) == 2 else {
            throw Failure.invalidDevices
        }
        microphone = inputs[0]
        output = previousOutput
    }

    func select() throws {
        try Self.setDefault(kAudioHardwarePropertyDefaultInputDevice, microphone)
        try verify()
    }

    func verify() throws {
        guard try Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) == microphone,
              try Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) == output else {
            throw Failure.routingChanged
        }
    }

    func restore() throws {
        var failure: Error?
        for (selector, device) in [(kAudioHardwarePropertyDefaultInputDevice, previousInput),
                                   (kAudioHardwarePropertyDefaultOutputDevice, previousOutput)] {
            do { try Self.setDefault(selector, device) } catch { failure = error }
        }
        if let failure { throw failure }
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device))
        guard device != 0 else { throw Failure.invalidDevices }
        return device
    }

    private static func setDefault(_ selector: AudioObjectPropertySelector, _ device: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = device
        try check(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                             UInt32(MemoryLayout<AudioObjectID>.size), &value))
        guard try defaultDevice(selector) == device else { throw Failure.routingChanged }
    }

    private static func channels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size))
        guard size >= UInt32(MemoryLayout<AudioBufferList>.size), size < 4096 else { throw Failure.invalidDevices }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory))
        let list = memory.assumingMemoryBound(to: AudioBufferList.self)
        let count = Int(list.pointee.mNumberBuffers)
        let required = MemoryLayout<AudioBufferList>.size + max(0, count - 1) * MemoryLayout<AudioBuffer>.stride
        guard count > 0, required <= Int(size) else { throw Failure.invalidDevices }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw Failure.coreAudio(status) }
    }

    private enum Failure: Error { case invalidDevices, routingChanged, coreAudio(OSStatus) }
}
