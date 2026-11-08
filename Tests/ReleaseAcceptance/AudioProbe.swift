import CoreAudio
import Darwin
import Foundation
import os

@main
struct AudioProbe {
    private static let blackHoleUID = "BlackHole2ch_UID"
    private static let frequency = 997.0
    private static let captureSeconds = 4.0
    private static let timeoutSeconds = 8.0

    private struct Device: Encodable {
        let id: AudioObjectID
        let uid: String
        let name: String
        let inputChannels: Int
        let outputChannels: Int
    }

    private struct Receipt: Encodable {
        var schemaVersion = 1
        var check = "blackhole-hal-loopback"
        var passed = false
        var devices: [Device] = []
        var selectedUID: String?
        var sampleRate: Double?
        var inputFrames = 0
        var outputFrames = 0
        var rms = 0.0
        var toneFraction = 0.0
        var defaultsRestored = true
        var error: String?
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private struct Samples: Sendable {
        var inputFrames = 0
        var outputFrames = 0
        var measuredFrames = 0
        var sumSquares = 0.0
        var sine = 0.0
        var cosine = 0.0
        var invalid = false
        var interrupted = false
    }

    private final class Stream: Sendable {
        let samples = OSAllocatedUnfairLock(initialState: Samples())
        let sampleRate: Double

        init(sampleRate: Double) { self.sampleRate = sampleRate }

        func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
            // CoreAudio buffers stay on this callback thread; the nonescaping closure never transfers them.
            samples.withLockUnchecked { state in
                let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                if let first = inputs.first, let data = first.mData, first.mNumberChannels > 0 {
                    let channels = Int(first.mNumberChannels)
                    let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
                    let values = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames {
                        let value = Double(values[frame * channels])
                        let index = state.inputFrames + frame
                        guard value.isFinite else { state.invalid = true; continue }
                        // Discard initial loopback latency; phase-independent correlation tolerates a fixed delay.
                        if index >= Int(sampleRate / 2) {
                            let phase = 2 * Double.pi * AudioProbe.frequency * Double(index) / sampleRate
                            state.sumSquares += value * value
                            state.sine += value * sin(phase)
                            state.cosine += value * cos(phase)
                            state.measuredFrames += 1
                        }
                    }
                    state.inputFrames += frames
                }
                let outputs = UnsafeMutableAudioBufferListPointer(output)
                var outputFrames: Int?
                for buffer in outputs {
                    guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
                    let channels = Int(buffer.mNumberChannels)
                    let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
                    if let outputFrames, outputFrames != frames { state.invalid = true }
                    outputFrames = frames
                    let values = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames {
                        let phase = 2 * Double.pi * AudioProbe.frequency
                            * Double(state.outputFrames + frame) / sampleRate
                        let tone = Float(0.1 * sin(phase))
                        for channel in 0..<channels { values[frame * channels + channel] = tone }
                    }
                }
                state.outputFrames += outputFrames ?? 0
            }
        }
    }

    static func main() {
        var receipt = Receipt()
        do {
            guard CommandLine.arguments.dropFirst() == ["--verify-blackhole"] else {
                throw Failure("usage: AudioProbe --verify-blackhole")
            }
            let environment = ProcessInfo.processInfo.environment
            guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_OS"] == "macOS" else {
                throw Failure("audio routing probe requires a disposable GitHub-hosted macOS job")
            }
            try verify(receipt: &receipt)
            receipt.passed = true
        } catch {
            receipt.error = String(describing: error)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            var data = try encoder.encode(receipt)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            exit(2)
        }
        exit(receipt.passed ? 0 : 1)
    }

    private static func verify(receipt: inout Receipt) throws {
        receipt.devices = try devices()
        let matches = receipt.devices.filter { $0.uid == blackHoleUID && $0.name == "BlackHole 2ch" }
        guard matches.count == 1, let device = matches.first,
              device.inputChannels == 2, device.outputChannels == 2 else {
            throw Failure("expected one BlackHole 2ch device with UID BlackHole2ch_UID and two input/output channels")
        }
        receipt.selectedUID = device.uid
        let inputFormat = try streamFormat(device.id, scope: kAudioObjectPropertyScopeInput)
        let outputFormat = try streamFormat(device.id, scope: kAudioObjectPropertyScopeOutput)
        guard inputFormat.mSampleRate == outputFormat.mSampleRate,
              inputFormat.mSampleRate.isFinite, inputFormat.mSampleRate >= 8_000 else {
            throw Failure("BlackHole input/output sample rates must match and be at least 8 kHz")
        }
        receipt.sampleRate = inputFormat.mSampleRate
        let stream = Stream(sampleRate: inputFormat.mSampleRate)
        let system = AudioObjectID(kAudioObjectSystemObject)
        let oldInput: AudioObjectID = try property(system, kAudioHardwarePropertyDefaultInputDevice, initial: 0)
        let oldOutput: AudioObjectID = try property(system, kAudioHardwarePropertyDefaultOutputDevice, initial: 0)
        var changedInput = false
        var changedOutput = false
        var proc: AudioDeviceIOProcID?
        var started = false
        var operationError: Error?

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { stream.samples.withLock { $0.interrupted = true } }
            source.resume()
            return source
        }
        defer { for source in sources { source.cancel() } }

        do {
            changedInput = true
            try setDefault(kAudioHardwarePropertyDefaultInputDevice, device.id)
            changedOutput = true
            try setDefault(kAudioHardwarePropertyDefaultOutputDevice, device.id)
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device.id, nil) { _, input, _, output, _ in
                stream.process(input: input, output: output)
            }, "create BlackHole IOProc")
            guard let proc else { throw Failure("CoreAudio returned no IOProc") }
            try check(AudioDeviceStart(device.id, proc), "start BlackHole IOProc")
            started = true
            let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                let current = stream.samples.withLock { $0 }
                if current.interrupted { throw Failure("interrupted") }
                if current.invalid { throw Failure("invalid or non-finite BlackHole samples") }
                if current.measuredFrames >= Int(stream.sampleRate * captureSeconds) { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            let current = stream.samples.withLock { $0 }
            receipt.inputFrames = current.inputFrames
            receipt.outputFrames = current.outputFrames
            guard current.measuredFrames >= Int(stream.sampleRate * captureSeconds) else {
                throw Failure("timed out waiting for BlackHole input callbacks")
            }
            receipt.rms = sqrt(current.sumSquares / Double(current.measuredFrames))
            if current.sumSquares > 0 {
                receipt.toneFraction = 2 * (current.sine * current.sine + current.cosine * current.cosine)
                    / (Double(current.measuredFrames) * current.sumSquares)
            }
            guard receipt.rms.isFinite, receipt.rms > 0.01,
                  receipt.toneFraction.isFinite, receipt.toneFraction > 0.8 else {
                throw Failure("BlackHole did not return the generated 997 Hz tone")
            }
        } catch {
            operationError = error
        }

        var cleanupErrors: [String] = []
        if let proc {
            if started {
                let status = AudioDeviceStop(device.id, proc)
                if status != noErr { cleanupErrors.append("stop IOProc: \(status)") }
            }
            let status = AudioDeviceDestroyIOProcID(device.id, proc)
            if status != noErr { cleanupErrors.append("destroy IOProc: \(status)") }
        }
        for (changed, selector, original) in [
            (changedOutput, kAudioHardwarePropertyDefaultOutputDevice, oldOutput),
            (changedInput, kAudioHardwarePropertyDefaultInputDevice, oldInput),
        ] where changed {
            do { try setDefault(selector, original) }
            catch {
                receipt.defaultsRestored = false
                cleanupErrors.append(String(describing: error))
            }
        }
        if let operationError { cleanupErrors.insert(String(describing: operationError), at: 0) }
        if !cleanupErrors.isEmpty { throw Failure(cleanupErrors.joined(separator: "; ")) }
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw Failure("\(operation): OSStatus \(status)") }
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                    initial: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutableBytes(of: &value) { bytes in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!),
                      "read HAL property \(selector)")
        }
        guard size == MemoryLayout<T>.size else { throw Failure("unexpected HAL property size") }
        return value
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        let value: Unmanaged<CFString>? = try property(object, selector, initial: nil)
        guard let value else { throw Failure("missing HAL device string") }
        return value.takeRetainedValue() as String
    }

    private static func devices() throws -> [Device] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size), "list HAL device size")
        guard size > 0, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else {
            throw Failure("no HAL devices")
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try ids.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!), "list HAL devices")
        }
        return try ids.map { id in
            try Device(id: id, uid: stringProperty(id, kAudioDevicePropertyDeviceUID),
                       name: stringProperty(id, kAudioObjectPropertyName),
                       inputChannels: channels(id, scope: kAudioObjectPropertyScopeInput),
                       outputChannels: channels(id, scope: kAudioObjectPropertyScopeOutput))
        }
    }

    private static func channels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "read channel count size")
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage), "read channel count")
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func streamFormat(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> AudioStreamBasicDescription {
        let format = try property(device, kAudioDevicePropertyStreamFormat, scope: scope,
                                  initial: AudioStreamBasicDescription())
        let channelsPerBuffer = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            ? 1 : format.mChannelsPerFrame
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mBitsPerChannel == 32, channelsPerBuffer > 0,
              format.mBytesPerFrame == channelsPerBuffer * UInt32(MemoryLayout<Float>.size) else {
            throw Failure("BlackHole must expose native Float32 PCM")
        }
        return format
    }

    private static func setDefault(_ selector: AudioObjectPropertySelector, _ device: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value = device
        let system = AudioObjectID(kAudioObjectSystemObject)
        try check(AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value),
                  "set default device \(selector)")
        let actual: AudioObjectID = try property(system, selector, initial: 0)
        guard actual == device else { throw Failure("default device readback mismatch") }
    }
}
