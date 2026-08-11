import AVFoundation
import CryptoKit
import Foundation
import JarvisCore

/// Synthetic, non-user speech generated once per run and replayed byte-identically across arms.
/// The files live only inside the benchmark run directory and are removed before the app exits.
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

    init(outputDirectory: URL) throws {
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
                let url = fixtureDirectory.appendingPathComponent("\(phrase.id).aiff")
                try Self.synthesize(phrase, to: url)
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
            try Self.writeSilence(duration: 1.5, to: endpointSilence)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: endpointSilence.path)
        } catch {
            let generationFailure = error
            // This initializer has not produced an owner yet, so perform its normal temporary-file
            // cleanup here rather than relying on `removeGeneratedAudio()`.
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
        to url: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "--voice", phrase.voice,
            "--rate", "175",
            "--output-file", url.path,
            // AIFF stores linear PCM in big-endian order; `say` rejects a little-endian format.
            "--data-format=BEI16@48000",
            phrase.text,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.synthesisFailed(phrase.id, process.terminationStatus)
        }
    }

    private static func writeSilence(duration: TimeInterval, to url: URL) throws {
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
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
