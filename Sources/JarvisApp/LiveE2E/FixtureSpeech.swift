#if JARVIS_LIVE_E2E // Debug builds only: see liveE2ESettings in Package.swift
import AVFoundation
import Foundation

/// `say` writes the transcription wire format (24 kHz mono PCM16), so nothing is resampled.
/// Speech files stay owner-only and are deleted once decoded, so no audio outlives the run.
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

    /// Throws if speech could not be removed, so a run never finishes with audio kept.
    func removeDirectory() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
#endif
