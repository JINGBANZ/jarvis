import AVFoundation
import CoreAudio
import Darwin
import Foundation
import os

@main
struct AudioRouteProbe {
    private static let systemUID = "BlackHole2ch_UID"
    private static let micFrequency = 997.0
    private static let systemFrequency = 1_601.0
    private static let captureSeconds = 4.0
    private static let emitSeconds = 8.0

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private struct Options {
        let mode: String
        let phase: String
        let micUID: String?
        let deviceUID: String
        let receipt: URL
        let acknowledgement: URL?

        init() throws {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count >= 2 else { throw Failure("missing mode") }
            mode = arguments[0]
            if mode == "--authorize" {
                guard arguments.count == 5, arguments[1] == "--acknowledgement", arguments[2].hasPrefix("/"),
                      arguments[3] == "--receipt", arguments[4].hasPrefix("/") else {
                    throw Failure("authorize requires absolute acknowledgement and receipt paths")
                }
                phase = "consent"
                micUID = nil
                deviceUID = ""
                acknowledgement = URL(fileURLWithPath: arguments[2]).standardizedFileURL
                receipt = URL(fileURLWithPath: arguments[4]).standardizedFileURL
                return
            }
            acknowledgement = nil
            phase = arguments[1]
            let expected = mode == "--capture" ? ["--mic-uid", "--system-uid", "--receipt"]
                : ["--device-uid", "--receipt"]
            guard (mode == "--capture" && ["mic-only", "system-only"].contains(phase))
                || (mode == "--emit" && ["mic", "system"].contains(phase)),
                  arguments.count == 2 + expected.count * 2 else { throw Failure("invalid mode arguments") }
            var values: [String: String] = [:]
            for (index, key) in expected.enumerated() {
                guard arguments[2 + index * 2] == key else { throw Failure("invalid option order") }
                values[key] = arguments[3 + index * 2]
            }
            deviceUID = values[mode == "--capture" ? "--system-uid" : "--device-uid"]!
            micUID = values["--mic-uid"]
            for value in [deviceUID, micUID].compactMap({ $0 }) {
                guard !value.isEmpty, value.utf8.count <= 128,
                      value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-").contains($0) }) else {
                    throw Failure("invalid device UID")
                }
            }
            guard (mode != "--capture" || (deviceUID == systemUID && micUID != deviceUID)),
                  (mode != "--emit" || phase != "system" || deviceUID == systemUID),
                  (mode != "--emit" || phase != "mic" || deviceUID != systemUID) else {
                throw Failure("microphone and system routes must use distinct devices")
            }
            let path = values["--receipt"]!
            guard path.hasPrefix("/") else { throw Failure("receipt path must be absolute") }
            receipt = URL(fileURLWithPath: path).standardizedFileURL
        }
    }

    private struct Metric: Codable, Sendable {
        var frames = 0
        var rms = 0.0
        var micToneAmplitude = 0.0
        var systemToneAmplitude = 0.0
        var micToneFraction = 0.0
        var systemToneFraction = 0.0
    }

    private struct Receipt: Encodable {
        let schemaVersion = 1
        var check = "audio-route-probe"
        var mode = "unknown"
        var phase = "unknown"
        var stage = "starting"
        var passed = false
        var micUID: String?
        var systemUID: String?
        var emitterUID: String?
        var sampleRate: Double?
        var micChannels: Int?
        var outputFrames = 0
        var rawMic = Metric()
        var globalTap = Metric()
        var defaultsRestored = true
        var resourcesReleased = true
        var microphoneAuthorized: Bool?
        var tapCreated: Bool?
        var nativeConsentAcknowledged: Bool?
        var captureGrantProven: Bool?
        var error: String?
    }

    private struct ConsentState: Sendable {
        var microphoneResult: Bool?
        var interrupted = false
    }

    private struct Accumulator: Sendable {
        var frames = 0
        var squares = 0.0
        var micSine = 0.0
        var micCosine = 0.0
        var systemSine = 0.0
        var systemCosine = 0.0

        mutating func append(_ value: Double, sampleRate: Double) {
            let micPhase = 2 * Double.pi * micFrequency * Double(frames) / sampleRate
            let systemPhase = 2 * Double.pi * systemFrequency * Double(frames) / sampleRate
            squares += value * value
            micSine += value * sin(micPhase)
            micCosine += value * cos(micPhase)
            systemSine += value * sin(systemPhase)
            systemCosine += value * cos(systemPhase)
            frames += 1
        }

        var metric: Metric {
            guard frames > 0 else { return Metric() }
            let count = Double(frames)
            let micPower = micSine * micSine + micCosine * micCosine
            let systemPower = systemSine * systemSine + systemCosine * systemCosine
            return Metric(frames: frames, rms: sqrt(squares / count),
                          micToneAmplitude: 2 * sqrt(micPower) / count,
                          systemToneAmplitude: 2 * sqrt(systemPower) / count,
                          micToneFraction: squares > 0 ? 2 * micPower / (count * squares) : 0,
                          systemToneFraction: squares > 0 ? 2 * systemPower / (count * squares) : 0)
        }
    }

    private struct State: Sendable {
        var interrupted = false
        var invalid = false
        var collecting = false
        var mic = Accumulator()
        var tap = Accumulator()
        var outputFrames = 0
    }

    private final class Stream: Sendable {
        let state = OSAllocatedUnfairLock(initialState: State())
        let sampleRate: Double
        let channels: Int
        let frequency: Double

        init(sampleRate: Double, channels: Int, frequency: Double = 0) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.frequency = frequency
        }

        func capture(_ input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
            // CoreAudio pointers remain on the callback thread inside this nonescaping lock closure.
            state.withLockUnchecked { current in
                for buffer in UnsafeMutableAudioBufferListPointer(output) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                guard current.collecting else { return }
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard buffers.count == 2 else { current.invalid = true; return }
                for index in 0..<2 {
                    let buffer = buffers[index]
                    let expectedChannels = index == 0 ? channels : 1
                    guard Int(buffer.mNumberChannels) == expectedChannels,
                          buffer.mDataByteSize > 0,
                          Int(buffer.mDataByteSize) % (MemoryLayout<Float>.size * expectedChannels) == 0,
                          let data = buffer.mData else { current.invalid = true; return }
                    let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / expectedChannels
                    let values = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames {
                        var mono = 0.0
                        for channel in 0..<expectedChannels {
                            mono += Double(values[frame * expectedChannels + channel]) / Double(expectedChannels)
                        }
                        guard mono.isFinite else { current.invalid = true; return }
                        if index == 0, current.mic.frames < Int(sampleRate * captureSeconds) {
                            current.mic.append(mono, sampleRate: sampleRate)
                        } else if index == 1, current.tap.frames < Int(sampleRate * captureSeconds) {
                            current.tap.append(mono, sampleRate: sampleRate)
                        }
                    }
                }
            }
        }

        func emit(_ output: UnsafeMutablePointer<AudioBufferList>) {
            // The mutable output buffer is never stored or transferred across threads.
            state.withLockUnchecked { current in
                let buffers = UnsafeMutableAudioBufferListPointer(output)
                guard buffers.count == 1, let buffer = buffers.first,
                      Int(buffer.mNumberChannels) == channels, let data = buffer.mData,
                      buffer.mDataByteSize > 0,
                      Int(buffer.mDataByteSize) % (MemoryLayout<Float>.size * channels) == 0 else {
                    current.invalid = true
                    return
                }
                let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
                let values = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    let index = current.outputFrames + frame
                    let tone = index < Int(sampleRate * emitSeconds) && !current.interrupted
                        ? Float(0.1 * sin(2 * Double.pi * frequency * Double(index) / sampleRate)) : 0
                    for channel in 0..<channels { values[frame * channels + channel] = tone }
                }
                current.outputFrames += frames
            }
        }
    }

    static func main() {
        var receipt = Receipt()
        var destination: FileHandle?
        do {
            let environment = ProcessInfo.processInfo.environment
            guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_OS"] == "macOS",
                  environment["RUNNER_ENVIRONMENT"] == "github-hosted",
                  NSUserName() == "runner", NSHomeDirectory() == "/Users/runner" else {
                throw Failure("requires a disposable GitHub-hosted macOS job")
            }
            let options = try Options()
            receipt.mode = String(options.mode.dropFirst(2))
            switch options.mode {
            case "--capture": receipt.check = "production-aggregate-route-isolation"
            case "--emit": receipt.check = "virtual-device-tone-emission"
            default: receipt.check = "fixture-capture-consent-bootstrap"
            }
            receipt.phase = options.phase
            destination = try openReceipt(options.receipt)
            if options.mode == "--capture" { try capture(options, receipt: &receipt) }
            else if options.mode == "--emit" { try emit(options, receipt: &receipt) }
            else { try authorize(options, receipt: &receipt) }
            receipt.passed = true
        } catch {
            receipt.error = String(describing: error)
        }
        receipt.stage = "complete"
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(receipt)
            data.append(0x0A)
            if let destination {
                try destination.write(contentsOf: data)
                try destination.synchronize()
                try destination.close()
            } else {
                try FileHandle.standardError.write(contentsOf: Data("Audio route probe refused its environment or receipt path.\n".utf8))
            }
        } catch { exit(2) }
        exit(receipt.passed ? 0 : 1)
    }

    private static func openReceipt(_ url: URL) throws -> FileHandle {
        try validatePrivateParent(url)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure("receipt must be a new owner-only file") }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func validatePrivateParent(_ url: URL) throws {
        guard let workspace = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"], workspace.hasPrefix("/") else {
            throw Failure("missing hosted workspace")
        }
        let root = URL(fileURLWithPath: workspace).appendingPathComponent(".jarvis/release-ui-probe").standardizedFileURL
        let parent = url.deletingLastPathComponent()
        guard parent.path.hasPrefix(root.path + "/"),
              parent.resolvingSymlinksInPath().path == parent.path else { throw Failure("invalid receipt directory") }
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw Failure("receipt directory must be owned and private")
        }
    }

    private static func signalSources(interrupt: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler(handler: interrupt)
            source.resume()
            return source
        }
    }

    private static func authorize(_ options: Options, receipt: inout Receipt) throws {
        receipt.microphoneAuthorized = false
        receipt.tapCreated = false
        receipt.nativeConsentAcknowledged = false
        receipt.captureGrantProven = false
        guard let acknowledgement = options.acknowledgement,
              acknowledgement != options.receipt,
              acknowledgement.deletingLastPathComponent() == options.receipt.deletingLastPathComponent() else {
            throw Failure("acknowledgement must use a distinct path in the same private run directory")
        }
        try validatePrivateParent(acknowledgement)
        var existing = stat()
        guard lstat(acknowledgement.path, &existing) == -1, errno == ENOENT else {
            throw Failure("acknowledgement must not exist before authorization")
        }
        let state = OSAllocatedUnfairLock(initialState: ConsentState())
        let sources = signalSources { state.withLock { $0.interrupted = true } }
        defer { for source in sources { source.cancel() } }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            state.withLock { $0.microphoneResult = granted }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            let current = state.withLock { $0 }
            if current.interrupted { throw Failure("interrupted") }
            if let granted = current.microphoneResult {
                receipt.microphoneAuthorized = granted && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard state.withLock({ $0.microphoneResult }) != nil else { throw Failure("microphone authorization request timed out") }
        guard receipt.microphoneAuthorized == true else { throw Failure("microphone authorization was not granted") }
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let creationStatus = AudioHardwareCreateProcessTap(description, &tap)
        receipt.tapCreated = creationStatus == noErr && tap != kAudioObjectUnknown
        var failure: Error?
        do {
            try check(creationStatus, "create consent bootstrap tap")
            guard receipt.tapCreated == true else { throw Failure("missing consent bootstrap tap") }
            try ready(options, stage: "authorization-ready")
            let acknowledgementDeadline = ProcessInfo.processInfo.systemUptime + 45
            while ProcessInfo.processInfo.systemUptime < acknowledgementDeadline {
                if state.withLock({ $0.interrupted }) { throw Failure("interrupted") }
                if try consentAcknowledged(acknowledgement) {
                    receipt.nativeConsentAcknowledged = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard receipt.nativeConsentAcknowledged == true else {
                throw Failure("native consent acknowledgement timed out")
            }
        } catch { failure = error }
        if tap != kAudioObjectUnknown {
            let destructionStatus = AudioHardwareDestroyProcessTap(tap)
            receipt.resourcesReleased = destructionStatus == noErr
            try check(destructionStatus, "destroy consent bootstrap tap")
        }
        if let failure { throw failure }
        guard !state.withLock({ $0.interrupted }) else { throw Failure("interrupted") }
    }

    private static func consentAcknowledged(_ url: URL) throws -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return false }
        guard descriptor >= 0 else { throw Failure("cannot open native consent acknowledgement") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        let expected = Data("fixture-native-consents-accepted-v1\n".utf8)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size == expected.count else { throw Failure("invalid native consent acknowledgement ownership or size") }
        guard try file.read(upToCount: expected.count + 1) == expected else {
            throw Failure("invalid native consent acknowledgement content")
        }
        return true
    }

    private static func ready(_ options: Options, stage: String = "ready") throws {
        let fields: [String: Any] = ["schemaVersion": 1, "stage": stage,
                                     "mode": String(options.mode.dropFirst(2)), "phase": options.phase]
        var data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        data.append(0x0A)
        let readyURL = options.receipt.deletingPathExtension().appendingPathExtension("ready")
        let destination = try openReceipt(readyURL)
        try destination.write(contentsOf: data)
        try destination.synchronize()
        try destination.close()
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func capture(_ options: Options, receipt: inout Receipt) throws {
        let mic = try device(uid: options.micUID!)
        let system = try device(uid: options.deviceUID)
        guard mic != system else { throw Failure("routes resolve to the same device") }
        let micFormat = try format(mic, scope: kAudioObjectPropertyScopeInput)
        let micOutputFormat = try format(mic, scope: kAudioObjectPropertyScopeOutput)
        guard micOutputFormat.mSampleRate == micFormat.mSampleRate,
              micOutputFormat.mChannelsPerFrame == micFormat.mChannelsPerFrame else {
            throw Failure("microphone fixture input and output formats differ")
        }
        let outputFormat = try format(system, scope: kAudioObjectPropertyScopeOutput)
        guard outputFormat.mChannelsPerFrame == 2 else { throw Failure("system route must be BlackHole 2ch") }
        receipt.micUID = options.micUID
        receipt.systemUID = options.deviceUID
        receipt.micChannels = Int(micFormat.mChannelsPerFrame)
        let oldInput: AudioObjectID = try property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: 0)
        let oldOutput: AudioObjectID = try property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: 0)
        guard oldInput != kAudioObjectUnknown, oldOutput != kAudioObjectUnknown else { throw Failure("missing original defaults") }
        let stream = Stream(sampleRate: micFormat.mSampleRate, channels: Int(micFormat.mChannelsPerFrame))
        let sources = signalSources { stream.state.withLock { $0.interrupted = true } }
        defer { for source in sources { source.cancel() } }
        var inputChanged = false
        var outputChanged = false
        var tap = AudioObjectID(kAudioObjectUnknown)
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var proc: AudioDeviceIOProcID?
        var started = false
        var failure: Error?
        do {
            inputChanged = true
            try setDefault(kAudioHardwarePropertyDefaultInputDevice, mic)
            outputChanged = true
            try setDefault(kAudioHardwarePropertyDefaultOutputDevice, system)
            let selected: AudioObjectID = try property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: 0)
            let selectedUID = try stringProperty(selected, kAudioDevicePropertyDeviceUID)
            guard selectedUID == options.micUID else { throw Failure("default input UID changed") }
            let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(tapDescription, &tap), "create global process tap")
            guard tap != kAudioObjectUnknown else { throw Failure("missing process tap") }
            let tapFormat: AudioStreamBasicDescription = try property(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            try validateFormat(tapFormat)
            guard tapFormat.mChannelsPerFrame == 1 else { throw Failure("tap is not mono") }
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Jarvis Route Probe",
                kAudioAggregateDeviceUIDKey: "com.jarvis.release-route.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: selectedUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: selectedUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                                                  kAudioSubTapDriftCompensationKey: 1]],
            ]
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate), "create microphone and tap aggregate")
            guard aggregate != kAudioObjectUnknown else { throw Failure("missing aggregate") }
            let rate: Float64 = try property(aggregate, kAudioDevicePropertyNominalSampleRate, initial: 0)
            guard rate.isFinite, rate == stream.sampleRate else { throw Failure("aggregate sample rate differs from microphone") }
            receipt.sampleRate = rate
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, output, _ in
                stream.capture(input, output: output)
            }, "create aggregate IOProc")
            guard let proc else { throw Failure("missing aggregate IOProc") }
            try check(AudioDeviceStart(aggregate, proc), "start aggregate IOProc")
            started = true
            try ready(options)
            let beginning = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - beginning < 12 {
                let elapsed = ProcessInfo.processInfo.systemUptime - beginning
                let state = stream.state.withLock { state in
                    if elapsed >= 2 { state.collecting = true }
                    return state
                }
                if state.interrupted { throw Failure("interrupted") }
                if state.invalid { throw Failure("missing or malformed aggregate buffers") }
                if state.mic.frames >= Int(rate * captureSeconds), state.tap.frames >= Int(rate * captureSeconds) { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            let state = stream.state.withLock { $0 }
            receipt.rawMic = state.mic.metric
            receipt.globalTap = state.tap.metric
            guard state.mic.frames >= Int(rate * captureSeconds), state.tap.frames >= Int(rate * captureSeconds) else {
                throw Failure("timed out waiting for both aggregate routes")
            }
            let finalInput: AudioObjectID = try property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: 0)
            let finalOutput: AudioObjectID = try property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: 0)
            guard finalInput == mic, finalOutput == system else { throw Failure("default route changed during measurement") }
            try score(options.phase, mic: receipt.rawMic, tap: receipt.globalTap)
        } catch { failure = error }
        var cleanup: [String] = []
        if let proc {
            if started { collect(AudioDeviceStop(aggregate, proc), "stop aggregate IOProc", into: &cleanup) }
            collect(AudioDeviceDestroyIOProcID(aggregate, proc), "destroy aggregate IOProc", into: &cleanup)
        }
        if aggregate != kAudioObjectUnknown { collect(AudioHardwareDestroyAggregateDevice(aggregate), "destroy aggregate", into: &cleanup) }
        if tap != kAudioObjectUnknown { collect(AudioHardwareDestroyProcessTap(tap), "destroy tap", into: &cleanup) }
        receipt.resourcesReleased = cleanup.isEmpty
        for (changed, selector, original) in [(outputChanged, kAudioHardwarePropertyDefaultOutputDevice, oldOutput),
                                               (inputChanged, kAudioHardwarePropertyDefaultInputDevice, oldInput)] where changed {
            do { try setDefault(selector, original) }
            catch { receipt.defaultsRestored = false; cleanup.append(String(describing: error)) }
        }
        if let failure { cleanup.insert(String(describing: failure), at: 0) }
        if !cleanup.isEmpty { throw Failure(cleanup.joined(separator: "; ")) }
    }

    private static func score(_ phase: String, mic: Metric, tap: Metric) throws {
        let intended = phase == "mic-only" ? mic : tap
        let amplitude = phase == "mic-only" ? intended.micToneAmplitude : intended.systemToneAmplitude
        let fraction = phase == "mic-only" ? intended.micToneFraction : intended.systemToneFraction
        guard intended.rms > 0.02, amplitude > 0.02, fraction > 0.8 else { throw Failure("intended route tone missing") }
        let leakage = phase == "mic-only" ? tap.micToneAmplitude : mic.systemToneAmplitude
        guard leakage < 0.001, leakage < amplitude * 0.01 else { throw Failure("tone leaked into the other capture route") }
        let inactive = phase == "mic-only" ? tap : mic
        guard inactive.rms < 0.001, inactive.rms < intended.rms * 0.01 else {
            throw Failure("unexpected energy in inactive capture route")
        }
        let unexpectedMic = phase == "mic-only" ? mic.systemToneAmplitude : mic.micToneAmplitude
        let unexpectedTap = phase == "mic-only" ? tap.systemToneAmplitude : tap.micToneAmplitude
        guard unexpectedMic < 0.001, unexpectedTap < 0.001 else {
            throw Failure("unexpected tone in capture routes")
        }
    }

    private static func emit(_ options: Options, receipt: inout Receipt) throws {
        let selected = try device(uid: options.deviceUID)
        let outputFormat = try format(selected, scope: kAudioObjectPropertyScopeOutput)
        receipt.emitterUID = options.deviceUID
        receipt.sampleRate = outputFormat.mSampleRate
        let stream = Stream(sampleRate: outputFormat.mSampleRate, channels: Int(outputFormat.mChannelsPerFrame),
                            frequency: options.phase == "mic" ? micFrequency : systemFrequency)
        let sources = signalSources { stream.state.withLock { $0.interrupted = true } }
        defer { for source in sources { source.cancel() } }
        var proc: AudioDeviceIOProcID?
        var started = false
        var failure: Error?
        do {
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, selected, nil) { _, _, _, output, _ in
                stream.emit(output)
            }, "create emitter IOProc")
            guard let proc else { throw Failure("missing emitter IOProc") }
            try check(AudioDeviceStart(selected, proc), "start emitter IOProc")
            started = true
            try ready(options)
            let beginning = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - beginning < 12 {
                let state = stream.state.withLock { $0 }
                if state.interrupted { throw Failure("interrupted") }
                if state.invalid { throw Failure("missing or malformed emitter buffers") }
                if state.outputFrames >= Int(stream.sampleRate * emitSeconds) { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            receipt.outputFrames = stream.state.withLock { $0.outputFrames }
            guard receipt.outputFrames >= Int(stream.sampleRate * emitSeconds) else { throw Failure("emitter callbacks timed out") }
        } catch { failure = error }
        var cleanup: [String] = []
        if let proc {
            if started { collect(AudioDeviceStop(selected, proc), "stop emitter IOProc", into: &cleanup) }
            collect(AudioDeviceDestroyIOProcID(selected, proc), "destroy emitter IOProc", into: &cleanup)
        }
        receipt.resourcesReleased = cleanup.isEmpty
        if let failure { cleanup.insert(String(describing: failure), at: 0) }
        if !cleanup.isEmpty { throw Failure(cleanup.joined(separator: "; ")) }
    }

    private static func device(uid: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size), "enumerate device size")
        guard size > 0, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { throw Failure("invalid device inventory") }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try devices.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!), "enumerate devices")
        }
        let matches = try devices.filter { try stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
        guard matches.count == 1, let selected = matches.first else { throw Failure("required unique device UID is unavailable") }
        let transport: UInt32 = try property(selected, kAudioDevicePropertyTransportType, initial: 0)
        guard transport == kAudioDeviceTransportTypeVirtual else { throw Failure("fixture requires a virtual device") }
        return selected
    }

    private static func format(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> AudioStreamBasicDescription {
        let value = try property(device, kAudioDevicePropertyStreamFormat, scope: scope, initial: AudioStreamBasicDescription())
        try validateFormat(value)
        return value
    }

    private static func validateFormat(_ format: AudioStreamBasicDescription) throws {
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              (format.mChannelsPerFrame == 1 || format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0),
              format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= 64,
              format.mBytesPerFrame == format.mChannelsPerFrame * UInt32(MemoryLayout<Float>.size),
              format.mFramesPerPacket == 1, format.mBytesPerPacket == format.mBytesPerFrame,
              format.mSampleRate.isFinite, format.mSampleRate >= 8_000, format.mSampleRate <= 192_000 else {
            throw Failure("route must use bounded interleaved native Float32 PCM")
        }
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutableBytes(of: &value) { bytes in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!), "read HAL property \(selector)")
        }
        guard size == MemoryLayout<T>.size else { throw Failure("unexpected HAL property size") }
        return value
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        let value: Unmanaged<CFString>? = try property(object, selector, initial: nil)
        guard let value else { throw Failure("missing device UID") }
        return value.takeRetainedValue() as String
    }

    private static func setDefault(_ selector: AudioObjectPropertySelector, _ device: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value = device
        let system = AudioObjectID(kAudioObjectSystemObject)
        try check(AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value), "set default device")
        let actual: AudioObjectID = try property(system, selector, initial: 0)
        guard actual == device else { throw Failure("default device readback mismatch") }
    }

    private static func collect(_ status: OSStatus, _ operation: String, into errors: inout [String]) {
        if status != noErr { errors.append("\(operation): OSStatus \(status)") }
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw Failure("\(operation): OSStatus \(status)") }
    }
}
