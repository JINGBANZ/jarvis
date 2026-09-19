#if JARVIS_LIVE_E2E // Debug builds only: see liveE2ESettings in Package.swift
import Foundation

public struct LiveE2EOptions: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case missing(String)
        case invalid(String)

        public var description: String {
            switch self {
            case .missing(let name): "Missing live e2e argument: \(name)"
            case .invalid(let detail): "Invalid live e2e arguments: \(detail)"
            }
        }
    }

    public let scenarioURL: URL
    public let outputDirectory: URL
    public let repositoryDirectory: URL
    public let fixturesDirectory: URL
    public let secretsDirectory: URL?

    public static var isRequested: Bool {
        isRequested(in: CommandLine.arguments)
    }

    public static func isRequested(in arguments: [String]) -> Bool {
        arguments.contains("--live-e2e")
    }

    public init(arguments: [String] = CommandLine.arguments) throws {
        guard let rawScenario = Self.value(after: "--live-e2e-scenario", in: arguments) else {
            throw Failure.missing("--live-e2e-scenario")
        }
        guard let rawOutput = Self.value(after: "--live-e2e-output-dir", in: arguments) else {
            throw Failure.missing("--live-e2e-output-dir")
        }
        guard let rawRepository = Self.value(after: "--live-e2e-repo-dir", in: arguments) else {
            throw Failure.missing("--live-e2e-repo-dir")
        }
        guard let rawFixtures = Self.value(after: "--live-e2e-fixtures-dir", in: arguments) else {
            throw Failure.missing("--live-e2e-fixtures-dir")
        }

        let scenario = URL(fileURLWithPath: rawScenario).standardizedFileURL
        guard Self.isRegularFile(scenario) else {
            throw Failure.invalid("--live-e2e-scenario is not an existing file: \(scenario.path)")
        }
        let fixtures = URL(fileURLWithPath: rawFixtures).standardizedFileURL
        guard Self.isDirectory(fixtures) else {
            throw Failure.invalid(
                "--live-e2e-fixtures-dir is not an existing directory: \(fixtures.path)")
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
        let liveE2EBase = repository
            .appendingPathComponent(".jarvis", isDirectory: true)
            .appendingPathComponent("live-e2e", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        // Two levels: each launch owns only its own `<run>/<id>` directory.
        let runDirectory = output.deletingLastPathComponent()
        guard runDirectory.deletingLastPathComponent().pathComponents == liveE2EBase.pathComponents,
              !runDirectory.lastPathComponent.isEmpty,
              !output.lastPathComponent.isEmpty else {
            throw Failure.invalid(
                "output must be a scenario directory exactly two levels under \(liveE2EBase.path)")
        }
        guard FileManager.default.fileExists(
            atPath: repository.appendingPathComponent("Package.swift").path
        ) else {
            throw Failure.invalid("repository directory does not contain Package.swift")
        }
        guard Self.isDirectory(output) else {
            throw Failure.invalid("output directory does not exist: \(output.path)")
        }
        // Anything besides the scenario copy would be stale evidence from an earlier launch.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
        guard contents.allSatisfy({ $0 == "scenario.json" }) else {
            throw Failure.invalid("output directory must be empty except for scenario.json")
        }

        var secrets: URL?
        if let rawSecrets = Self.value(after: "--live-e2e-secrets-dir", in: arguments) {
            let url = URL(fileURLWithPath: rawSecrets).standardizedFileURL
            guard Self.isDirectory(url) else {
                throw Failure.invalid(
                    "--live-e2e-secrets-dir is not an existing directory: \(url.path)")
            }
            secrets = url
        }

        scenarioURL = scenario
        outputDirectory = output
        repositoryDirectory = repository
        fixturesDirectory = fixtures
        secretsDirectory = secrets
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
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
#endif
