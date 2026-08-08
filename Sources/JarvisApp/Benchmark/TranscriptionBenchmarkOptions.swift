import Foundation
import JarvisCore

struct TranscriptionBenchmarkOptions: Sendable {
    enum Mode: String, Sendable {
        case standard
        case reconnect
    }

    enum Failure: Error, CustomStringConvertible {
        case missing(String)
        case invalid(String)

        var description: String {
            switch self {
            case .missing(let name): "Missing benchmark argument: \(name)"
            case .invalid(let detail): "Invalid benchmark arguments: \(detail)"
            }
        }
    }

    let mode: Mode
    let outputDirectory: URL
    let repositoryDirectory: URL
    let repetitions: Int

    static var isRequested: Bool {
        CommandLine.arguments.contains("--transcription-benchmark")
    }

    init(arguments: [String] = CommandLine.arguments) throws {
        guard let rawMode = Self.value(after: "--benchmark-mode", in: arguments),
              let mode = Mode(rawValue: rawMode) else {
            throw Failure.missing("--benchmark-mode standard|reconnect")
        }
        guard let rawOutput = Self.value(after: "--benchmark-output-dir", in: arguments) else {
            throw Failure.missing("--benchmark-output-dir")
        }
        guard let rawRepository = Self.value(after: "--benchmark-repo-dir", in: arguments) else {
            throw Failure.missing("--benchmark-repo-dir")
        }
        let output = URL(fileURLWithPath: rawOutput).standardizedFileURL
        let repository = URL(fileURLWithPath: rawRepository).standardizedFileURL
        let benchmarkBase = repository
            .appendingPathComponent(".jarvis", isDirectory: true)
            .appendingPathComponent("transcription-benchmarks", isDirectory: true)
            .standardizedFileURL
        guard output.path.hasPrefix(benchmarkBase.path + "/") else {
            throw Failure.invalid("output must be a run directory under \(benchmarkBase.path)")
        }
        guard FileManager.default.fileExists(
            atPath: repository.appendingPathComponent("Package.swift").path
        ) else {
            throw Failure.invalid("repository directory does not contain Package.swift")
        }
        let repetitions = Int(Self.value(after: "--benchmark-repetitions", in: arguments) ?? "3") ?? 0
        guard repetitions >= 3 else {
            throw Failure.invalid("--benchmark-repetitions must be at least 3")
        }
        if mode == .reconnect,
           !arguments.contains("--benchmark-network-interruption-confirmed") {
            throw Failure.invalid(
                "reconnect mode requires --benchmark-network-interruption-confirmed")
        }

        self.mode = mode
        outputDirectory = output
        repositoryDirectory = repository
        self.repetitions = repetitions
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}
