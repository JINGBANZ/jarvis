import Foundation

public struct TranscriptionBenchmarkOptions: Sendable {
    public enum Mode: String, Sendable {
        case standard
        case reconnect
    }

    public enum Failure: Error, CustomStringConvertible {
        case missing(String)
        case invalid(String)

        public var description: String {
            switch self {
            case .missing(let name): "Missing benchmark argument: \(name)"
            case .invalid(let detail): "Invalid benchmark arguments: \(detail)"
            }
        }
    }

    public let mode: Mode
    public let outputDirectory: URL
    public let repositoryDirectory: URL
    public let repetitions: Int

    public static var isRequested: Bool {
        CommandLine.arguments.contains("--transcription-benchmark")
    }

    public init(arguments: [String] = CommandLine.arguments) throws {
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
        let requestedOutput = URL(fileURLWithPath: rawOutput).standardizedFileURL
        let requestedRepository = URL(fileURLWithPath: rawRepository).standardizedFileURL
        guard requestedOutput.pathComponents.starts(
            with: requestedRepository.pathComponents
        ) else {
            throw Failure.invalid("output must be inside the repository directory")
        }
        guard !Self.containsSymbolicLink(
            in: requestedOutput,
            relativeTo: requestedRepository
        ) else {
            throw Failure.invalid("output path must not contain symbolic links")
        }
        let output = requestedOutput.resolvingSymlinksInPath().standardizedFileURL
        let repository = requestedRepository.resolvingSymlinksInPath().standardizedFileURL
        let benchmarkBase = repository
            .appendingPathComponent(".jarvis", isDirectory: true)
            .appendingPathComponent("transcription-benchmarks", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard output.deletingLastPathComponent() == benchmarkBase,
              !output.lastPathComponent.isEmpty else {
            throw Failure.invalid(
                "output must be an immediate run directory under \(benchmarkBase.path)")
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

    private static func containsSymbolicLink(in url: URL, relativeTo base: URL) -> Bool {
        var current = base
        for component in url.pathComponents.dropFirst(base.pathComponents.count) {
            current.appendPathComponent(component)
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: current.path
            ) else { continue }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                return true
            }
        }
        return false
    }
}
