import Foundation
import Testing
@testable import JarvisCore

@Suite("Transcription benchmark files")
struct TranscriptionBenchmarkFilesTests {
    @Test("output and atomically replaced files remain owner-only")
    func ownerOnlyAtomicReplacement() throws {
        let root = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("run")
        try TranscriptionBenchmarkFiles.prepareOutputDirectory(output)

        try TranscriptionBenchmarkFiles.writeText("old", named: "result.txt", to: output)
        try TranscriptionBenchmarkFiles.writeText("new", named: "result.txt", to: output)

        let result = output.appendingPathComponent("result.txt")
        #expect(try String(contentsOf: result, encoding: .utf8) == "new")
        let directoryPermissions = try FileManager.default.attributesOfItem(
            atPath: output.path)[.posixPermissions] as? NSNumber
        let filePermissions = try FileManager.default.attributesOfItem(
            atPath: result.path)[.posixPermissions] as? NSNumber
        #expect(directoryPermissions?.intValue == 0o700)
        #expect(filePermissions?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["result.txt"])
    }

    @Test("file names cannot escape the benchmark run directory")
    func rejectsTraversal() throws {
        let root = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("run")
        try TranscriptionBenchmarkFiles.prepareOutputDirectory(output)

        #expect(throws: (any Error).self) {
            try TranscriptionBenchmarkFiles.writeText(
                "escape",
                named: "../outside.txt",
                to: output)
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("outside.txt").path))
    }
}
