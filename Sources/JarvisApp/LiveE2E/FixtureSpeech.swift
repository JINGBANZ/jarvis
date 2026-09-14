import AVFoundation
import Foundation

/// Speech for the live e2e scenarios, synthesized with the system voice at run time so no audio is
/// ever committed. `say` writes 24 kHz mono PCM16 directly, the transcription wire format, so the
/// samples need no resampling or downmix. Each file lives only between synthesis and decoding, in
/// an owner-only directory inside the scenario's run directory.
struct FixtureSpeech {
    enum Failure: Error, CustomStringConvertible {
        case synthesisFailed(Int32)
        case unexpectedFormat(String)

        var description: String {
            switch self {
            case .synthesisFailed(let status): "Speech synthesis failed (status \(status))"
            case .unexpectedFormat(let detail): "Synthesized speech had an unexpected format: \(detail)"
            }
        }
    }

    let directory: URL

    func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    func samples(for text: String, voice: String) throws -> [Int16] {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "--voice", voice,
            "--rate", "175",
            "--output-file", url.path,
            "--data-format=LEI16@24000",
            text,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.synthesisFailed(process.terminationStatus)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        guard file.fileFormat.sampleRate == 24_000, file.fileFormat.channelCount == 1 else {
            throw Failure.unexpectedFormat(
                "\(file.fileFormat.sampleRate) Hz, \(file.fileFormat.channelCount) channels")
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else {
            throw Failure.unexpectedFormat("no buffer for \(file.length) frames")
        }
        try file.read(into: buffer)
        guard let channel = buffer.int16ChannelData else {
            throw Failure.unexpectedFormat("not 16-bit integer samples")
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}
