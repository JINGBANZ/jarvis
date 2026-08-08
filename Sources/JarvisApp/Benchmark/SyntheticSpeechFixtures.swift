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
            // This initializer has not produced an owner yet, so perform its normal temporary-file
            // cleanup here rather than relying on `removeGeneratedAudio()`.
            if createdDirectory,
               fixtureDirectory.deletingLastPathComponent() == standardizedOutput,
               fixtureDirectory.lastPathComponent == "fixtures" {
                try? FileManager.default.removeItem(at: fixtureDirectory)
            }
            throw error
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

    func removeGeneratedAudio() {
        let expected = outputDirectory.appendingPathComponent("fixtures", isDirectory: true)
            .standardizedFileURL
        guard directory == expected,
              directory.deletingLastPathComponent() == outputDirectory else {
            jlog("Jarvis benchmark: refused to remove an unexpected fixture directory")
            return
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            jlog("Jarvis benchmark: could not remove synthetic fixtures: \(error)")
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case synthesisFailed(String, Int32)
        case missingFixture(String)
        case invalidAudioFormat
        case fixtureDirectoryAlreadyExists

        var description: String {
            switch self {
            case .synthesisFailed(let id, let status):
                "Speech synthesis failed for \(id) (status \(status))"
            case .missingFixture(let id): "Missing synthetic fixture \(id)"
            case .invalidAudioFormat: "Could not construct the synthetic silence format"
            case .fixtureDirectoryAlreadyExists:
                "The benchmark run directory already contains a fixtures directory"
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
            "--data-format=LEI16@48000",
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
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(duration * format.sampleRate)) else {
            throw Failure.invalidAudioFormat
        }
        buffer.frameLength = buffer.frameCapacity
        buffer.int16ChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
