import Foundation
import Testing
@testable import JarvisCore

@Suite("Transcription benchmark options")
struct TranscriptionBenchmarkOptionsTests {
    @Test("standard mode accepts only a run below the repository benchmark tree")
    func parsesStandardRun() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let output = repository.appendingPathComponent(
            ".jarvis/transcription-benchmarks/standard-run")

        let options = try TranscriptionBenchmarkOptions(arguments: arguments(
            mode: "standard",
            output: output,
            repository: repository,
            repetitions: "4"))

        #expect(options.mode == .standard)
        #expect(options.outputDirectory.path == output.standardizedFileURL.path)
        #expect(options.repositoryDirectory.path == repository.standardizedFileURL.path)
        #expect(options.repetitions == 4)
    }

    @Test("a similarly prefixed sibling is outside the allowed benchmark tree")
    func rejectsSiblingOutputTree() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let output = repository.appendingPathComponent(
            ".jarvis/transcription-benchmarks-escape/run")

        #expect(throws: (any Error).self) {
            try TranscriptionBenchmarkOptions(arguments: arguments(
                mode: "standard",
                output: output,
                repository: repository,
                repetitions: "3"))
        }
    }

    @Test("output must be an immediate benchmark run directory")
    func rejectsNestedOutputTree() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let output = repository.appendingPathComponent(
            ".jarvis/transcription-benchmarks/nested/run")

        #expect(throws: (any Error).self) {
            try TranscriptionBenchmarkOptions(arguments: arguments(
                mode: "standard",
                output: output,
                repository: repository,
                repetitions: "3"))
        }
    }

    @Test("a symlink cannot redirect benchmark output")
    func rejectsSymlinkedOutput() throws {
        let repository = try makeRepository()
        let outside = ActivityLogTests.tmp()
        defer {
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: outside)
        }
        let base = repository.appendingPathComponent(
            ".jarvis/transcription-benchmarks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true)
        let output = base.appendingPathComponent("redirected-run")
        try FileManager.default.createSymbolicLink(
            at: output,
            withDestinationURL: outside)

        #expect(throws: (any Error).self) {
            try TranscriptionBenchmarkOptions(arguments: arguments(
                mode: "standard",
                output: output,
                repository: repository,
                repetitions: "3"))
        }
    }

    @Test("reconnect mode is scoped and keeps the repetition floor")
    func validatesReconnectSafetyArguments() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let output = repository.appendingPathComponent(
            ".jarvis/transcription-benchmarks/reconnect-run")

        #expect(try TranscriptionBenchmarkOptions(arguments: arguments(
            mode: "reconnect",
            output: output,
            repository: repository,
            repetitions: "3")).mode == .reconnect)
        #expect(throws: (any Error).self) {
            try TranscriptionBenchmarkOptions(arguments: arguments(
                mode: "standard",
                output: output,
                repository: repository,
                repetitions: "2"))
        }
    }

    private func makeRepository() throws -> URL {
        let repository = ActivityLogTests.tmp()
        try Data("// test package".utf8).write(
            to: repository.appendingPathComponent("Package.swift"))
        return repository
    }

    private func arguments(
        mode: String,
        output: URL,
        repository: URL,
        repetitions: String
    ) -> [String] {
        [
            "Jarvis",
            "--transcription-benchmark",
            "--benchmark-mode", mode,
            "--benchmark-output-dir", output.path,
            "--benchmark-repo-dir", repository.path,
            "--benchmark-repetitions", repetitions,
        ]
    }
}
