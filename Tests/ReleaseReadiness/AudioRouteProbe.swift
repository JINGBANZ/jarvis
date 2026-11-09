import AppKit
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import os

@main
struct AudioRouteProbe {
    private static let systemUID = "BlackHole2ch_UID"
    private static let inputUID = "com.jarvis.release-input"
    private static let micFrequency = 997.0
    private static let systemFrequency = 1_601.0
    private static let captureSeconds = 4.0
    private static let emitSeconds = 8.0
    private static let quitRequested = OSAllocatedUnfairLock(initialState: false)

    @MainActor
    private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            DispatchQueue.global(qos: .userInitiated).async { runProbe() }
        }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            quitRequested.withLock { $0 = true }
            // The worker must release CoreAudio resources and restore defaults before exiting.
            return .terminateCancel
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        let reason: FailureReason
        let status: OSStatus?
        init(_ description: String, reason: FailureReason = .validation, status: OSStatus? = nil) {
            self.description = description
            self.reason = reason
            self.status = status
        }
    }

    private enum FailureStage: String, Encodable {
        case arguments, paths, operation, formats, defaults, tap, aggregate, capture, score, cleanup
        case deviceSelection = "device-selection"
        case ioProc = "io-proc"
        case phaseStart = "phase-start"
        case ioStart = "io-start"
        case finalDefaults = "final-defaults"
        case finalQuit = "final-quit"
        case senderSetup = "sender-setup"
        case senderStart = "sender-start"
        case senderProgress = "sender-progress"
        case senderExit = "sender-exit"
        case senderDuration = "sender-duration"
    }

    private enum FailureReason: String, Encodable {
        case validation, interrupted, timeout, cleanup, other
        case osStatus = "os-status"
        case invalidBuffers = "invalid-buffers"
        case defaultsChanged = "defaults-changed"
        case intendedToneMissing = "intended-tone-missing"
        case toneLeak = "tone-leak"
        case unexpectedEnergy = "unexpected-energy"
        case unexpectedTone = "unexpected-tone"
        case childExit = "child-exit"
        case durationMismatch = "duration-mismatch"
    }

    private enum InvalidBufferReason: String, Encodable, Sendable {
        case count, channels, bytes
        case missingData = "missing-data"
        case nonFinite = "non-finite"
    }

    private struct InvalidBuffer: Sendable {
        let reason: InvalidBufferReason
        let uptime: Double
        let count: Int
        let index: Int?
        let channels: Int?
        let byteSize: Int?
        let hasData: Bool?
    }

    private struct DeviceState: Encodable {
        let uptime = ProcessInfo.processInfo.systemUptime
        var queryFailed = false
        var queryOSStatus: OSStatus?
        var micEnumerated: Bool?
        var micAlive: Bool?
        var micObjectMatchesRequested: Bool?
        var aggregateActiveSubdeviceCount: Int?
        var aggregateMicActive: Bool?
        var aggregateActiveTapCount: Int?
        var aggregateTapMatchesRequested: Bool?
        var defaultInputMatchesRequested: Bool?
        var defaultInputMatchesAggregate: Bool?
    }

    private struct Options {
        let mode: String
        let phase: String
        let micUID: String?
        let deviceUID: String
        let receipt: URL
        let acknowledgement: URL?
        let input: URL?
        let start: URL?

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
                input = nil
                start = nil
                receipt = URL(fileURLWithPath: arguments[4]).standardizedFileURL
                return
            }
            acknowledgement = nil
            phase = arguments[1]
            let expected = mode == "--capture" ? ["--mic-uid", "--system-uid", "--start", "--receipt"]
                : phase == "system" ? ["--device-uid", "--start", "--receipt"] : ["--device-uid", "--input", "--start", "--receipt"]
            guard (mode == "--capture" && ["mic-only", "system-only"].contains(phase))
                || (mode == "--emit" && ["mic", "mic-quiet", "system"].contains(phase)),
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
            guard (mode != "--capture" || (deviceUID == systemUID && micUID == inputUID)),
                  (mode != "--emit" || phase != "system" || deviceUID == systemUID),
                  (mode != "--emit" || phase == "system" || deviceUID == inputUID) else {
                throw Failure("microphone and system routes must use distinct devices")
            }
            let path = values["--receipt"]!
            guard path.hasPrefix("/") else { throw Failure("receipt path must be absolute") }
            receipt = URL(fileURLWithPath: path).standardizedFileURL
            guard let startPath = values["--start"], startPath.hasPrefix("/") else { throw Failure("start path must be absolute") }
            start = URL(fileURLWithPath: startPath).standardizedFileURL
            if let path = values["--input"] {
                guard path.hasPrefix("/") else { throw Failure("input path must be absolute") }
                input = URL(fileURLWithPath: path).standardizedFileURL
            } else { input = nil }
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

    private enum AuthorizationStage: String, Encodable {
        case paths, microphone, tap, aggregate, acknowledgement, cleanup
        case ioProc = "io-proc"
        case ioStart = "io-start"
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
        var transport: String?
        var wireSampleRate: Int?
        var sourceDurationSeconds: Double?
        var outputDurationSeconds: Double?
        var senderElapsedSeconds: Double?
        var senderExitCode: Int32?
        var senderReaped: Bool?
        var senderStartUptime: Double?
        var senderEndUptime: Double?
        var measurementStartUptime: Double?
        var measurementEndUptime: Double?
        var rawMic = Metric()
        var globalTap = Metric()
        var defaultsRestored = true
        var resourcesReleased = true
        var microphoneAuthorized: Bool?
        var microphoneRequestUptime: Double?
        var microphoneCompletionUptime: Double?
        var microphoneFinishedUptime: Double?
        var microphoneAuthorizationStatus: Int?
        var microphoneCallbackReceived: Bool?
        var tapCreated: Bool?
        var ioStarted: Bool?
        var ioStartRequestedUptime: Double?
        var ioStartReturnedUptime: Double?
        var authorizationFailureStage: AuthorizationStage?
        var nativeConsentAcknowledged: Bool?
        var captureGrantProven: Bool?
        var failureStage: FailureStage?
        var failureReason: FailureReason?
        var failureOSStatus: OSStatus?
        var finalDefaultInputMatchesRequested: Bool?
        var finalDefaultOutputMatchesRequested: Bool?
        var invalidBufferReason: InvalidBufferReason?
        var invalidBufferUptime: Double?
        var invalidBufferCount: Int?
        var invalidBufferIndex: Int?
        var invalidBufferChannels: Int?
        var invalidBufferByteSize: Int?
        var invalidBufferHasData: Bool?
        var beforeIOState: DeviceState?
        var failureState: DeviceState?
        var error: String?
    }

    private struct ConsentState: Sendable {
        var microphoneResult: Bool?
        var microphoneCompletionUptime: Double?
        var interrupted = false
    }

    private struct SenderProgress {
        var pending = Data()
        var bytesRead = 0
        var recordMicroseconds: Int64?
        var recordHasTimestamp = false
        var outputMicroseconds: Int64 = 0
        var firstOutputUptime: Double?
        var lastOutputUptime: Double?
        var ended = false

        mutating func read(_ input: FileHandle) throws {
            let data = try input.read(upToCount: 131_073 - bytesRead) ?? Data()
            bytesRead += data.count
            guard bytesRead <= 131_072 else { throw Failure("RTP sender progress exceeds bound") }
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                guard !ended, let line = String(data: pending[..<newline], encoding: .ascii) else {
                    throw Failure("invalid RTP sender progress record")
                }
                pending.removeSubrange(...newline)
                if line.hasPrefix("out_time_us=") {
                    guard !recordHasTimestamp else { throw Failure("duplicate RTP sender output timestamp") }
                    recordHasTimestamp = true
                    let timestamp = line.dropFirst("out_time_us=".count)
                    if timestamp != "N/A" {
                        guard let value = Int64(timestamp), value >= 0 else {
                            throw Failure("invalid RTP sender output timestamp")
                        }
                        recordMicroseconds = value
                    }
                } else if line.hasPrefix("progress=") {
                    guard line == "progress=continue" || line == "progress=end",
                          recordHasTimestamp else {
                        throw Failure("incomplete RTP sender progress")
                    }
                    guard let value = recordMicroseconds else {
                        guard line == "progress=continue", outputMicroseconds == 0 else {
                            throw Failure("RTP sender output timestamp disappeared")
                        }
                        recordHasTimestamp = false
                        continue
                    }
                    guard value >= outputMicroseconds else {
                        throw Failure("incomplete or regressing RTP sender progress")
                    }
                    if value > outputMicroseconds {
                        let now = ProcessInfo.processInfo.systemUptime
                        if firstOutputUptime == nil { firstOutputUptime = now }
                        lastOutputUptime = now
                        outputMicroseconds = value
                    }
                    recordMicroseconds = nil
                    recordHasTimestamp = false
                    ended = line == "progress=end"
                }
            }
        }
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
        var firstFrameUptime: Double?
        var lastFrameUptime: Double?
        var invalidBuffer: InvalidBuffer?

        mutating func invalidate(_ reason: InvalidBufferReason, count: Int, index: Int? = nil, buffer: AudioBuffer? = nil) {
            invalid = true
            if invalidBuffer == nil {
                invalidBuffer = InvalidBuffer(reason: reason, uptime: ProcessInfo.processInfo.systemUptime,
                                              count: count, index: index,
                                              channels: buffer.map { Int($0.mNumberChannels) },
                                              byteSize: buffer.map { Int($0.mDataByteSize) },
                                              hasData: buffer.map { $0.mData != nil })
            }
        }
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
                let measuring = current.mic.frames < Int(sampleRate * captureSeconds)
                    || current.tap.frames < Int(sampleRate * captureSeconds)
                if measuring {
                    let now = ProcessInfo.processInfo.systemUptime
                    if current.firstFrameUptime == nil { current.firstFrameUptime = now }
                    current.lastFrameUptime = now
                }
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard buffers.count == 2 else {
                    current.invalidate(.count, count: buffers.count, index: buffers.isEmpty ? nil : 0, buffer: buffers.first)
                    return
                }
                for index in 0..<2 {
                    let buffer = buffers[index]
                    let expectedChannels = index == 0 ? channels : 1
                    guard Int(buffer.mNumberChannels) == expectedChannels else {
                        current.invalidate(.channels, count: buffers.count, index: index, buffer: buffer); return
                    }
                    guard buffer.mDataByteSize > 0,
                          Int(buffer.mDataByteSize) % (MemoryLayout<Float>.size * expectedChannels) == 0 else {
                        current.invalidate(.bytes, count: buffers.count, index: index, buffer: buffer); return
                    }
                    guard let data = buffer.mData else {
                        current.invalidate(.missingData, count: buffers.count, index: index, buffer: buffer); return
                    }
                    let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / expectedChannels
                    let values = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames {
                        var mono = 0.0
                        for channel in 0..<expectedChannels {
                            mono += Double(values[frame * expectedChannels + channel]) / Double(expectedChannels)
                        }
                        guard mono.isFinite else {
                            current.invalidate(.nonFinite, count: buffers.count, index: index, buffer: buffer); return
                        }
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
                if current.outputFrames < Int(sampleRate * emitSeconds) {
                    let now = ProcessInfo.processInfo.systemUptime
                    if current.firstFrameUptime == nil { current.firstFrameUptime = now }
                    current.lastFrameUptime = now
                }
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

    @MainActor
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_OS"] == "macOS",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              NSUserName() == "runner", NSHomeDirectory() == "/Users/runner" else {
            do {
                try FileHandle.standardError.write(contentsOf: Data("Audio route probe requires a disposable GitHub-hosted macOS job.\n".utf8))
            } catch { exit(2) }
            exit(1)
        }
        let application = NSApplication.shared
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.prohibited) // ghost-mode-allowed: hidden synthetic fixture on an explicitly authorized hosted Mac
        withExtendedLifetime(delegate) { application.run() }
    }

    private static func runProbe() {
        var receipt = Receipt()
        var destination: FileHandle?
        var operation = FailureStage.arguments
        do {
            let options = try Options()
            receipt.mode = String(options.mode.dropFirst(2))
            switch options.mode {
            case "--capture": receipt.check = "production-aggregate-route-isolation"
            case "--emit": receipt.check = options.phase == "system" ? "virtual-device-tone-emission" : "synthetic-microphone-rtp"
            default: receipt.check = "fixture-capture-consent-bootstrap"
            }
            receipt.phase = options.phase
            operation = .paths
            destination = try openReceipt(options.receipt)
            if let start = options.start {
                try validatePrivateParent(start)
                guard start.deletingLastPathComponent() == options.receipt.deletingLastPathComponent(),
                      start != options.receipt, start != options.input,
                      !FileManager.default.fileExists(atPath: start.path) else { throw Failure("phase start must be new and private") }
            }
            try checkQuitRequest()
            operation = .operation
            if options.mode == "--capture" { try capture(options, receipt: &receipt) }
            else if options.mode == "--emit" { try emit(options, receipt: &receipt) }
            else { try authorize(options, receipt: &receipt) }
            operation = .finalQuit
            try checkQuitRequest()
            receipt.passed = true
        } catch {
            receipt.error = String(describing: error)
            receipt.failureStage = receipt.failureStage ?? operation
            receipt.failureReason = (error as? Failure)?.reason ?? .other
            receipt.failureOSStatus = (error as? Failure)?.status
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

    private static func checkQuitRequest() throws {
        if quitRequested.withLock({ $0 }) { throw Failure("interrupted", reason: .interrupted) }
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
        receipt.ioStarted = false
        receipt.nativeConsentAcknowledged = false
        receipt.captureGrantProven = false
        let state = OSAllocatedUnfairLock(initialState: ConsentState())
        let sources = signalSources { state.withLock { $0.interrupted = true } }
        defer { for source in sources { source.cancel() } }
        var stage = AuthorizationStage.paths
        var tap = AudioObjectID(kAudioObjectUnknown)
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var proc: AudioDeviceIOProcID?
        var started = false
        var failure: Error?
        do {
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
            stage = .microphone
            try checkQuitRequest()
            receipt.microphoneRequestUptime = ProcessInfo.processInfo.systemUptime
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                let completed = ProcessInfo.processInfo.systemUptime
                state.withLock {
                    $0.microphoneCompletionUptime = completed
                    $0.microphoneResult = granted
                }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            do {
                defer {
                    let current = state.withLock { $0 }
                    receipt.microphoneCompletionUptime = current.microphoneCompletionUptime
                    receipt.microphoneFinishedUptime = ProcessInfo.processInfo.systemUptime
                    receipt.microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
                    receipt.microphoneCallbackReceived = current.microphoneResult != nil
                }
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try checkQuitRequest()
                    let current = state.withLock { $0 }
                    if current.interrupted { throw Failure("interrupted") }
                    if let granted = current.microphoneResult {
                        receipt.microphoneAuthorized = granted && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            guard state.withLock({ $0.microphoneResult }) != nil else { throw Failure("microphone authorization request timed out") }
            guard receipt.microphoneAuthorized == true else { throw Failure("microphone authorization was not granted") }
            try checkQuitRequest()
            stage = .tap
            let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
            description.isPrivate = true
            description.muteBehavior = .unmuted
            let creationStatus = AudioHardwareCreateProcessTap(description, &tap)
            receipt.tapCreated = creationStatus == noErr && tap != kAudioObjectUnknown
            try check(creationStatus, "create consent bootstrap tap")
            guard receipt.tapCreated == true else { throw Failure("missing consent bootstrap tap") }

            stage = .aggregate
            let output: AudioObjectID = try property(AudioObjectID(kAudioObjectSystemObject),
                                                    kAudioHardwarePropertyDefaultOutputDevice, initial: 0)
            guard output != kAudioObjectUnknown else { throw Failure("missing consent bootstrap clock") }
            let outputUID = try stringProperty(output, kAudioDevicePropertyDeviceUID)
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Jarvis Route Consent",
                kAudioAggregateDeviceUIDKey: "com.jarvis.release-route.consent.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
                      "create consent bootstrap aggregate")
            guard aggregate != kAudioObjectUnknown else { throw Failure("missing consent bootstrap aggregate") }
            stage = .ioProc
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, _, _, output, _ in
                for buffer in UnsafeMutableAudioBufferListPointer(output) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
            }, "create consent bootstrap IOProc")
            guard let proc else { throw Failure("missing consent bootstrap IOProc") }
            stage = .ioStart
            try checkQuitRequest()
            if state.withLock({ $0.interrupted }) { throw Failure("interrupted") }
            // CoreAudio requests permission when recording starts, not when the tap object is created.
            receipt.ioStartRequestedUptime = ProcessInfo.processInfo.systemUptime
            let startStatus = AudioDeviceStart(aggregate, proc)
            receipt.ioStartReturnedUptime = ProcessInfo.processInfo.systemUptime
            started = startStatus == noErr
            receipt.ioStarted = started
            try check(startStatus, "start consent bootstrap IOProc")

            stage = .acknowledgement
            try ready(options, stage: "authorization-ready")
            let acknowledgementDeadline = ProcessInfo.processInfo.systemUptime + 45
            while ProcessInfo.processInfo.systemUptime < acknowledgementDeadline {
                try checkQuitRequest()
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
        } catch {
            receipt.authorizationFailureStage = stage
            failure = error
        }
        var cleanup: [String] = []
        if let proc {
            if started { collect(AudioDeviceStop(aggregate, proc), "stop consent bootstrap IOProc", into: &cleanup) }
            collect(AudioDeviceDestroyIOProcID(aggregate, proc), "destroy consent bootstrap IOProc", into: &cleanup)
        }
        if aggregate != kAudioObjectUnknown { collect(AudioHardwareDestroyAggregateDevice(aggregate), "destroy consent bootstrap aggregate", into: &cleanup) }
        if tap != kAudioObjectUnknown { collect(AudioHardwareDestroyProcessTap(tap), "destroy consent bootstrap tap", into: &cleanup) }
        receipt.resourcesReleased = cleanup.isEmpty
        if !cleanup.isEmpty {
            receipt.authorizationFailureStage = .cleanup
            if let failure { cleanup.insert(String(describing: failure), at: 0) }
            throw Failure(cleanup.joined(separator: "; "))
        }
        if let failure { throw failure }
        guard !state.withLock({ $0.interrupted }) else { throw Failure("interrupted") }
    }

    private static func consentAcknowledged(_ url: URL, content: String = "fixture-native-consents-accepted-v1\n") throws -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return false }
        guard descriptor >= 0 else { throw Failure("cannot open native consent acknowledgement") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        let expected = Data(content.utf8)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size == expected.count else { throw Failure("invalid native consent acknowledgement ownership or size") }
        guard try file.read(upToCount: expected.count + 1) == expected else {
            throw Failure("invalid native consent acknowledgement content")
        }
        return true
    }

    private static func awaitStart(_ options: Options, interrupted: () -> Bool) throws {
        let beginning = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - beginning < 45 {
            try checkQuitRequest()
            if interrupted() { throw Failure("interrupted", reason: .interrupted) }
            if try consentAcknowledged(options.start!, content: "fixture-phase-start-v1\n") { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw Failure("phase start acknowledgement timed out", reason: .timeout)
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
        var operation = FailureStage.deviceSelection
        var completed = false
        defer { if !completed, receipt.failureStage == nil { receipt.failureStage = operation } }
        let mic = try device(uid: options.micUID!)
        let system = try device(uid: options.deviceUID)
        guard mic != system else { throw Failure("routes resolve to the same device") }
        operation = .formats
        let micFormat = try microphoneFormat(mic)
        let outputFormat = try format(system, scope: kAudioObjectPropertyScopeOutput)
        guard outputFormat.mChannelsPerFrame == 2, outputFormat.mSampleRate == 48_000 else {
            throw Failure("system route must be BlackHole 2ch at 48000 Hz")
        }
        receipt.micUID = options.micUID
        receipt.systemUID = options.deviceUID
        receipt.micChannels = Int(micFormat.mChannelsPerFrame)
        operation = .defaults
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
        var requestedTapUID: String?
        var proc: AudioDeviceIOProcID?
        var started = false
        var failure: Error?
        do {
            try checkQuitRequest()
            inputChanged = true
            try setDefault(kAudioHardwarePropertyDefaultInputDevice, mic)
            outputChanged = true
            try setDefault(kAudioHardwarePropertyDefaultOutputDevice, system)
            let selected: AudioObjectID = try property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: 0)
            let selectedUID = try stringProperty(selected, kAudioDevicePropertyDeviceUID)
            guard selectedUID == options.micUID else { throw Failure("default input UID changed", reason: .defaultsChanged) }
            operation = .tap
            let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
            requestedTapUID = tapDescription.uuid.uuidString
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(tapDescription, &tap), "create global process tap")
            guard tap != kAudioObjectUnknown else { throw Failure("missing process tap") }
            let tapFormat: AudioStreamBasicDescription = try property(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            try validateFormat(tapFormat)
            guard tapFormat.mChannelsPerFrame == 1, tapFormat.mSampleRate == micFormat.mSampleRate else {
                throw Failure("tap must be mono at the microphone sample rate")
            }
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Jarvis Route Probe",
                kAudioAggregateDeviceUIDKey: "com.jarvis.release-route.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: selectedUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: selectedUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                                                  kAudioSubTapDriftCompensationKey: 1]],
            ]
            operation = .aggregate
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate), "create microphone and tap aggregate")
            guard aggregate != kAudioObjectUnknown else { throw Failure("missing aggregate") }
            let rate: Float64 = try property(aggregate, kAudioDevicePropertyNominalSampleRate, initial: 0)
            guard rate.isFinite, rate == stream.sampleRate else { throw Failure("aggregate sample rate differs from microphone") }
            receipt.sampleRate = rate
            operation = .ioProc
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, output, _ in
                stream.capture(input, output: output)
            }, "create aggregate IOProc")
            guard let proc else { throw Failure("missing aggregate IOProc") }
            receipt.beforeIOState = deviceState(mic: mic, aggregate: aggregate, tapUID: tapDescription.uuid.uuidString)
            operation = .phaseStart
            try ready(options)
            try awaitStart(options, interrupted: { stream.state.withLock { $0.interrupted } })
            try checkQuitRequest()
            operation = .ioStart
            try check(AudioDeviceStart(aggregate, proc), "start aggregate IOProc")
            started = true
            operation = .capture
            let beginning = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - beginning < 12 {
                try checkQuitRequest()
                let elapsed = ProcessInfo.processInfo.systemUptime - beginning
                let state = stream.state.withLock { state in
                    if elapsed >= 2 { state.collecting = true }
                    return state
                }
                if state.interrupted { throw Failure("interrupted", reason: .interrupted) }
                if state.invalid { throw Failure("missing or malformed aggregate buffers", reason: .invalidBuffers) }
                if state.mic.frames >= Int(rate * captureSeconds), state.tap.frames >= Int(rate * captureSeconds) { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            let state = stream.state.withLock { $0 }
            receipt.rawMic = state.mic.metric
            receipt.globalTap = state.tap.metric
            receipt.measurementStartUptime = state.firstFrameUptime
            receipt.measurementEndUptime = state.lastFrameUptime
            guard state.mic.frames >= Int(rate * captureSeconds), state.tap.frames >= Int(rate * captureSeconds) else {
                throw Failure("timed out waiting for both aggregate routes", reason: .timeout)
            }
            operation = .finalDefaults
            let finalInput: AudioObjectID = try property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: 0)
            receipt.finalDefaultInputMatchesRequested = finalInput == mic
            let finalOutput: AudioObjectID = try property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: 0)
            receipt.finalDefaultOutputMatchesRequested = finalOutput == system
            guard finalInput == mic, finalOutput == system else {
                throw Failure("default route changed during measurement", reason: .defaultsChanged)
            }
            operation = .score
            try score(options.phase, mic: receipt.rawMic, tap: receipt.globalTap)
        } catch {
            failure = error
            receipt.failureStage = operation
            if aggregate != kAudioObjectUnknown, let requestedTapUID {
                receipt.failureState = deviceState(mic: mic, aggregate: aggregate, tapUID: requestedTapUID)
            }
        }
        operation = .cleanup
        var cleanup: [String] = []
        var cleanupStatus: OSStatus?
        func recordCleanup(_ status: OSStatus, _ description: String) {
            if status != noErr, cleanupStatus == nil { cleanupStatus = status }
            collect(status, description, into: &cleanup)
        }
        if let proc {
            if started { recordCleanup(AudioDeviceStop(aggregate, proc), "stop aggregate IOProc") }
            recordCleanup(AudioDeviceDestroyIOProcID(aggregate, proc), "destroy aggregate IOProc")
        }
        if aggregate != kAudioObjectUnknown { recordCleanup(AudioHardwareDestroyAggregateDevice(aggregate), "destroy aggregate") }
        if tap != kAudioObjectUnknown { recordCleanup(AudioHardwareDestroyProcessTap(tap), "destroy tap") }
        receipt.resourcesReleased = cleanup.isEmpty
        let observed = stream.state.withLock { $0 }
        receipt.rawMic = observed.mic.metric
        receipt.globalTap = observed.tap.metric
        receipt.measurementStartUptime = observed.firstFrameUptime
        receipt.measurementEndUptime = observed.lastFrameUptime
        receipt.invalidBufferReason = observed.invalidBuffer?.reason
        receipt.invalidBufferUptime = observed.invalidBuffer?.uptime
        receipt.invalidBufferCount = observed.invalidBuffer?.count
        receipt.invalidBufferIndex = observed.invalidBuffer?.index
        receipt.invalidBufferChannels = observed.invalidBuffer?.channels
        receipt.invalidBufferByteSize = observed.invalidBuffer?.byteSize
        receipt.invalidBufferHasData = observed.invalidBuffer?.hasData
        for (changed, selector, original) in [(outputChanged, kAudioHardwarePropertyDefaultOutputDevice, oldOutput),
                                               (inputChanged, kAudioHardwarePropertyDefaultInputDevice, oldInput)] where changed {
            do { try setDefault(selector, original) }
            catch {
                receipt.defaultsRestored = false
                if cleanupStatus == nil { cleanupStatus = (error as? Failure)?.status }
                cleanup.append(String(describing: error))
            }
        }
        if let failure { cleanup.insert(String(describing: failure), at: 0) }
        if !cleanup.isEmpty {
            throw Failure(cleanup.joined(separator: "; "),
                          reason: (failure as? Failure)?.reason ?? (failure == nil ? .cleanup : .other),
                          status: (failure as? Failure)?.status ?? cleanupStatus)
        }
        completed = true
    }

    private static func deviceState(mic: AudioObjectID, aggregate: AudioObjectID, tapUID: String) -> DeviceState {
        var result = DeviceState()
        let system = AudioObjectID(kAudioObjectSystemObject)
        func observe(_ query: () throws -> Void) {
            do { try query() }
            catch {
                result.queryFailed = true
                if result.queryOSStatus == nil { result.queryOSStatus = (error as? Failure)?.status }
            }
        }
        observe {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
            var uid = inputUID as CFString
            var current = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try withUnsafePointer(to: &uid) { qualifier in
                try check(AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size),
                                                     qualifier, &size, &current), "translate requested microphone UID")
            }
            guard size == MemoryLayout<AudioObjectID>.size else { throw Failure("invalid microphone identity size") }
            result.micObjectMatchesRequested = current == mic
            let devices = try objectList(system, kAudioHardwarePropertyDevices)
            result.micEnumerated = current != kAudioObjectUnknown && devices.contains(current)
            if current == kAudioObjectUnknown { result.micAlive = false }
            else {
                let alive: UInt32 = try property(current, kAudioDevicePropertyDeviceIsAlive, initial: 0)
                result.micAlive = alive != 0
            }
        }
        observe {
            let active = try objectList(aggregate, kAudioAggregateDevicePropertyActiveSubDeviceList)
            result.aggregateActiveSubdeviceCount = active.count
            result.aggregateMicActive = try active.contains { try stringProperty($0, kAudioDevicePropertyDeviceUID) == inputUID }
        }
        observe {
            let active = try objectList(aggregate, kAudioAggregateDevicePropertySubTapList)
            result.aggregateActiveTapCount = active.count
            let value: Unmanaged<CFArray>? = try property(aggregate, kAudioAggregateDevicePropertyTapList, initial: nil)
            guard let value, let taps = value.takeRetainedValue() as? [String], taps.count <= 4096 else {
                throw Failure("invalid aggregate tap identities")
            }
            result.aggregateTapMatchesRequested = taps == [tapUID]
        }
        observe {
            let selected: AudioObjectID = try property(system, kAudioHardwarePropertyDefaultInputDevice, initial: 0)
            result.defaultInputMatchesAggregate = selected == aggregate
            result.defaultInputMatchesRequested = try selected != kAudioObjectUnknown
                && stringProperty(selected, kAudioDevicePropertyDeviceUID) == inputUID
        }
        return result
    }

    private static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "read diagnostic object list size")
        guard size % UInt32(MemoryLayout<AudioObjectID>.size) == 0,
              size <= 4096 * MemoryLayout<AudioObjectID>.size else { throw Failure("invalid diagnostic object list size") }
        if size == 0 { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let capacity = size
        try values.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!), "read diagnostic object list")
        }
        guard size <= capacity, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else {
            throw Failure("invalid diagnostic object list result")
        }
        return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func score(_ phase: String, mic: Metric, tap: Metric) throws {
        let intended = phase == "mic-only" ? mic : tap
        let amplitude = phase == "mic-only" ? intended.micToneAmplitude : intended.systemToneAmplitude
        let fraction = phase == "mic-only" ? intended.micToneFraction : intended.systemToneFraction
        guard intended.rms > 0.02, amplitude > 0.02, fraction > 0.8 else {
            throw Failure("intended route tone missing", reason: .intendedToneMissing)
        }
        let leakage = phase == "mic-only" ? tap.micToneAmplitude : mic.systemToneAmplitude
        guard leakage < 0.001, leakage < amplitude * 0.01 else {
            throw Failure("tone leaked into the other capture route", reason: .toneLeak)
        }
        let inactive = phase == "mic-only" ? tap : mic
        guard inactive.rms < 0.001, inactive.rms < intended.rms * 0.01 else {
            throw Failure("unexpected energy in inactive capture route", reason: .unexpectedEnergy)
        }
        let unexpectedMic = phase == "mic-only" ? mic.systemToneAmplitude : mic.micToneAmplitude
        let unexpectedTap = phase == "mic-only" ? tap.systemToneAmplitude : tap.micToneAmplitude
        guard unexpectedMic < 0.001, unexpectedTap < 0.001 else {
            throw Failure("unexpected tone in capture routes", reason: .unexpectedTone)
        }
    }

    private static func emit(_ options: Options, receipt: inout Receipt) throws {
        if options.phase != "system" {
            try emitMicrophone(options, receipt: &receipt)
            return
        }
        let selected = try device(uid: options.deviceUID)
        let outputFormat = try format(selected, scope: kAudioObjectPropertyScopeOutput)
        receipt.emitterUID = options.deviceUID
        receipt.sampleRate = outputFormat.mSampleRate
        let stream = Stream(sampleRate: outputFormat.mSampleRate, channels: Int(outputFormat.mChannelsPerFrame),
                            frequency: systemFrequency)
        let sources = signalSources { stream.state.withLock { $0.interrupted = true } }
        defer { for source in sources { source.cancel() } }
        var proc: AudioDeviceIOProcID?
        var started = false
        var failure: Error?
        do {
            try checkQuitRequest()
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, selected, nil) { _, _, _, output, _ in
                stream.emit(output)
            }, "create emitter IOProc")
            guard let proc else { throw Failure("missing emitter IOProc") }
            try ready(options)
            try awaitStart(options, interrupted: { stream.state.withLock { $0.interrupted } })
            try checkQuitRequest()
            try check(AudioDeviceStart(selected, proc), "start emitter IOProc")
            started = true
            let beginning = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - beginning < 12 {
                try checkQuitRequest()
                let state = stream.state.withLock { $0 }
                if state.interrupted { throw Failure("interrupted") }
                if state.invalid { throw Failure("missing or malformed emitter buffers") }
                if state.outputFrames >= Int(stream.sampleRate * emitSeconds) { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            receipt.outputFrames = stream.state.withLock { $0.outputFrames }
            receipt.senderStartUptime = stream.state.withLock { $0.firstFrameUptime }
            receipt.senderEndUptime = stream.state.withLock { $0.lastFrameUptime }
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

    private static func emitMicrophone(_ options: Options, receipt: inout Receipt) throws {
        var operation = FailureStage.senderSetup
        var completed = false
        defer { if !completed, receipt.failureStage == nil { receipt.failureStage = operation } }
        let selected = try device(uid: options.deviceUID)
        let inputFormat = try microphoneFormat(selected)
        receipt.emitterUID = options.deviceUID
        receipt.sampleRate = inputFormat.mSampleRate
        receipt.micChannels = Int(inputFormat.mChannelsPerFrame)
        receipt.transport = "rtp"
        receipt.wireSampleRate = 44_100
        receipt.senderReaped = false
        guard let inputURL = options.input,
              inputURL.deletingLastPathComponent() == options.receipt.deletingLastPathComponent() else {
            throw Failure("synthetic input must belong to this private run")
        }
        let input = try privateInput(inputURL, maximumBytes: 22_000_000)
        defer { try? input.close() }
        let data = try input.readToEnd() ?? Data()
        let duration = try waveDuration(data, quiet: options.phase == "mic-quiet")
        try input.seek(toOffset: 0)
        receipt.sourceDurationSeconds = duration
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
        var info = stat()
        guard executable.resolvingSymlinksInPath().path == executable.path,
              lstat(executable.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0, info.st_mode & 0o100 != 0 else {
            throw Failure("missing owned bundled RTP sender")
        }
        let progressURL = options.receipt.deletingPathExtension().appendingPathExtension("progress")
        let progress = try openReceipt(progressURL)
        defer { try? progress.close() }
        let progressInput = try privateInput(progressURL, maximumBytes: 131_072, allowEmpty: true)
        defer { try? progressInput.close() }
        var observedProgress = SenderProgress()
        let errors = try openReceipt(options.receipt.deletingPathExtension().appendingPathExtension("stderr"))
        defer { try? errors.close() }
        let child = Process()
        child.executableURL = executable
        child.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        child.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-nostats", "-re", "-i", "pipe:0",
                           "-map", "0:a:0", "-c:a", "pcm_s16be", "-ar", "44100", "-ac", "2",
                           "-f", "rtp", "-payload_type", "10", "-sdp_file", "/dev/null", "-progress", "pipe:1",
                           "rtp://127.0.0.1:10001?rtcpport=10002&pkt_size=1200&connect=1"]
        child.standardInput = input
        child.standardOutput = progress
        child.standardError = errors
        let interrupted = OSAllocatedUnfairLock(initialState: false)
        let sources = signalSources { interrupted.withLock { $0 = true } }
        defer { for source in sources { source.cancel() } }
        var launched = false
        var failure: Error?
        var senderBeginning: Double?
        do {
            operation = .phaseStart
            try ready(options)
            try awaitStart(options, interrupted: { interrupted.withLock { $0 } })
            operation = .senderStart
            try child.run()
            launched = true
            let beginning = ProcessInfo.processInfo.systemUptime
            senderBeginning = beginning
            operation = .senderProgress
            while child.isRunning, ProcessInfo.processInfo.systemUptime - beginning < duration + 5 {
                try checkQuitRequest()
                if interrupted.withLock({ $0 }) { throw Failure("interrupted", reason: .interrupted) }
                try observedProgress.read(progressInput)
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard !child.isRunning else { throw Failure("RTP sender timed out", reason: .timeout) }
            receipt.senderElapsedSeconds = ProcessInfo.processInfo.systemUptime - beginning
            try observedProgress.read(progressInput)
        } catch { failure = error; receipt.failureStage = operation }
        if receipt.senderElapsedSeconds == nil, let senderBeginning {
            receipt.senderElapsedSeconds = ProcessInfo.processInfo.systemUptime - senderBeginning
        }
        receipt.senderStartUptime = observedProgress.firstOutputUptime
        receipt.senderEndUptime = observedProgress.lastOutputUptime
        if observedProgress.outputMicroseconds > 0 {
            receipt.outputDurationSeconds = Double(observedProgress.outputMicroseconds) / 1_000_000
        }
        operation = .cleanup
        if launched {
            if child.isRunning {
                child.terminate()
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while child.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
            }
            if child.isRunning {
                // Process retains ownership of this direct child; never signal a name or process group.
                _ = kill(child.processIdentifier, SIGKILL)
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while child.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
            }
            receipt.senderReaped = !child.isRunning
            receipt.resourcesReleased = !child.isRunning
            if !child.isRunning {
                child.waitUntilExit()
                receipt.senderExitCode = child.terminationStatus
            }
        } else { receipt.senderReaped = true }
        guard receipt.resourcesReleased else {
            receipt.failureStage = .cleanup
            throw Failure("RTP sender cleanup did not complete", reason: .cleanup)
        }
        if let failure { throw failure }
        operation = .senderExit
        guard child.terminationReason == .exit, receipt.senderExitCode == 0 else { throw Failure("RTP sender failed", reason: .childExit) }
        operation = .senderProgress
        guard observedProgress.ended, observedProgress.pending.isEmpty,
              !observedProgress.recordHasTimestamp, observedProgress.outputMicroseconds > 0 else {
            throw Failure("RTP sender did not finish its bounded input")
        }
        let outputDuration = Double(observedProgress.outputMicroseconds) / 1_000_000
        receipt.outputDurationSeconds = outputDuration
        operation = .senderDuration
        guard outputDuration >= duration, outputDuration <= duration + 0.1,
              let elapsed = receipt.senderElapsedSeconds, elapsed >= duration - 1, elapsed <= duration + 5 else {
            throw Failure("RTP sender duration or pacing mismatch", reason: .durationMismatch)
        }
        completed = true
    }

    private static func privateInput(_ url: URL, maximumBytes: Int, allowEmpty: Bool = false) throws -> FileHandle {
        try validatePrivateParent(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure("cannot open private synthetic input") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
              info.st_size >= (allowEmpty ? 0 : 1), info.st_size <= maximumBytes else {
            try file.close()
            throw Failure("synthetic input must be a bounded owner-only regular file")
        }
        return file
    }

    private static func waveDuration(_ data: Data, quiet: Bool) throws -> Double {
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ length: Int) -> Int {
            (0..<length).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        guard bytes.count >= 44, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE", number(4, 4) + 8 == bytes.count else {
            throw Failure("synthetic input must be a complete PCM WAV")
        }
        var offset = 12
        var validatedFormat = false
        var audio: Range<Int>?
        while offset + 8 <= bytes.count {
            let name = String(bytes: bytes[offset..<offset + 4], encoding: .ascii)
            let size = number(offset + 4, 4)
            let begin = offset + 8
            guard size <= bytes.count - begin else { throw Failure("invalid WAV chunk bound") }
            if name == "fmt " {
                guard !validatedFormat, size == 16, number(begin, 2) == 1, number(begin + 2, 2) == 2,
                      number(begin + 4, 4) == 44_100, number(begin + 8, 4) == 176_400,
                      number(begin + 12, 2) == 4, number(begin + 14, 2) == 16 else {
                    throw Failure("synthetic WAV must use stereo PCM16 at 44100 Hz")
                }
                validatedFormat = true
            } else if name == "data" {
                guard audio == nil, size > 0, size % 4 == 0 else { throw Failure("invalid WAV audio chunk") }
                audio = begin..<begin + size
            }
            offset = begin + size + size % 2
        }
        guard offset == bytes.count, validatedFormat, let audio else { throw Failure("incomplete WAV input") }
        let duration = Double(audio.count) / 176_400
        guard duration >= 1, duration <= 120 else { throw Failure("synthetic WAV duration exceeds bounds") }
        if quiet, !bytes[audio].allSatisfy({ $0 == 0 }) { throw Failure("quiet microphone phase requires explicit zero PCM") }
        return duration
    }

    private static func microphoneFormat(_ device: AudioObjectID) throws -> AudioStreamBasicDescription {
        let value = try format(device, scope: kAudioObjectPropertyScopeInput)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                mScope: kAudioObjectPropertyScopeOutput,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "read microphone output streams")
        guard size == 0, value.mChannelsPerFrame == 2, value.mSampleRate == 48_000 else {
            throw Failure("synthetic microphone must be input-only stereo at 48000 Hz")
        }
        return value
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
        guard actual == device else { throw Failure("default device readback mismatch", reason: .defaultsChanged) }
    }

    private static func collect(_ status: OSStatus, _ operation: String, into errors: inout [String]) {
        if status != noErr { errors.append("\(operation): OSStatus \(status)") }
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw Failure("\(operation): OSStatus \(status)", reason: .osStatus, status: status) }
    }
}
