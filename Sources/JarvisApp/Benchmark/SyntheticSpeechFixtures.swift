import AVFoundation
import CryptoKit
import Foundation
import JarvisCore
import JarvisProcess

final class SyntheticSpeechFixtures {
    struct Fixture: Sendable {
        let phrase: TranscriptionBenchmark.Phrase
        let fileURL: URL
        let sha256: String
    }

    let fixtures: [String: Fixture]
    let silenceURL: URL

    private let directory: URL
    private let outputDirectory: URL

    init(outputDirectory: URL, launcher: any ProcessLaunching) throws {
        let standardizedOutput = outputDirectory.standardizedFileURL
        let fixtureDirectory = outputDirectory.appendingPathComponent("fixtures", isDirectory: true)
            .standardizedFileURL
        let endpointSilence = fixtureDirectory.appendingPathComponent("endpoint-silence.caf")
        var generated: [String: Fixture] = [:]
        var createdDirectory = false
        do {
            guard !FileManager.default.fileExists(atPath: fixtureDirectory.path) else {
                throw Failure.fixtureDirectoryAlreadyExists
            }
            try FileManager.default.createDirectory(
                at: fixtureDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            createdDirectory = true
            for phrase in TranscriptionBenchmark.phrases {
                let url = fixtureDirectory.appendingPathComponent("\(phrase.id).caf")
                if phrase.text.isEmpty {
                    try Self.writeControl(duration: 3, noise: phrase.id == "noise", to: url)
                } else {
                    try Self.synthesize(phrase, to: url, launcher: launcher)
                }
                let data = try Data(contentsOf: url)
                generated[phrase.id] = Fixture(
                    phrase: phrase,
                    fileURL: url,
                    sha256: SHA256.hash(data: data).map {
                        String(format: "%02x", $0)
                    }.joined())
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            try Self.writeControl(duration: 1.5, noise: false, to: endpointSilence)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: endpointSilence.path)
        } catch {
            let generationFailure = error
            // No instance exists yet to call `removeGeneratedAudio()`, so clean up here.
            if createdDirectory,
               fixtureDirectory.deletingLastPathComponent() == standardizedOutput,
               fixtureDirectory.lastPathComponent == "fixtures" {
                do {
                    try FileManager.default.removeItem(at: fixtureDirectory)
                } catch {
                    jlog("Jarvis benchmark: fixture generation failed with \(generationFailure); "
                         + "partial-fixture cleanup also failed: \(error)")
                    throw error
                }
            }
            throw generationFailure
        }

        self.outputDirectory = standardizedOutput
        directory = fixtureDirectory
        fixtures = generated
        silenceURL = endpointSilence
    }

    func fixture(for phrase: TranscriptionBenchmark.Phrase) throws -> Fixture {
        guard let fixture = fixtures[phrase.id] else {
            throw Failure.missingFixture(phrase.id)
        }
        return fixture
    }

    func removeGeneratedAudio() throws {
        let expected = outputDirectory.appendingPathComponent("fixtures", isDirectory: true)
            .standardizedFileURL
        guard directory == expected,
              directory.deletingLastPathComponent() == outputDirectory else {
            throw Failure.unexpectedFixtureDirectory
        }
        try FileManager.default.removeItem(at: directory)
    }

    enum Failure: Error, CustomStringConvertible {
        case synthesisFailed(String, Int32)
        case missingFixture(String)
        case invalidAudioFormat
        case fixtureDirectoryAlreadyExists
        case unexpectedFixtureDirectory

        var description: String {
            switch self {
            case .synthesisFailed(let id, let status):
                "Speech synthesis failed for \(id) (status \(status))"
            case .missingFixture(let id): "Missing synthetic fixture \(id)"
            case .invalidAudioFormat: "Could not construct the synthetic silence format"
            case .fixtureDirectoryAlreadyExists:
                "The benchmark run directory already contains a fixtures directory"
            case .unexpectedFixtureDirectory:
                "Refused to remove an unexpected fixture directory"
            }
        }
    }

    private static func synthesize(
        _ phrase: TranscriptionBenchmark.Phrase,
        to url: URL, launcher: any ProcessLaunching
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "--voice", phrase.voice,
            "--rate", "175",
            "--output-file", url.path,
            "--data-format=LEI16@48000",
            phrase.text,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try launcher.launch(process)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.synthesisFailed(phrase.id, process.terminationStatus)
        }
    }

    private static func writeControl(duration: TimeInterval, noise: Bool, to url: URL) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(duration * format.sampleRate)),
              let samples = buffer.floatChannelData?[0] else {
            throw Failure.invalidAudioFormat
        }
        buffer.frameLength = buffer.frameCapacity
        // Match AVAudioFile's standard float processing format. Passing an integer buffer to the
        // writer's float conversion path aborts inside AudioToolbox on macOS 26 instead of throwing.
        samples.initialize(repeating: 0, count: Int(buffer.frameLength))
        if noise {
            var seed: UInt64 = 444
            for index in 0..<Int(buffer.frameLength) {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                samples[index] = (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.04
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
