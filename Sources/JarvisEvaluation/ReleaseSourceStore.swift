import Foundation
import JarvisCore
import JarvisBrainProviders

/// No cache on purpose: the agent CLI needs the network anyway, so one could never rescue an
/// offline run. Never copy session artifacts here.
public struct ReleaseSourceStore: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case invalidVersion
        case tagNotFound(String)
        case fetchFailed(String)
        case unpackFailed(String)
        case noAvailableSource

        public var errorDescription: String? {
            switch self {
            case .invalidVersion:
                "I can't read a valid Jarvis version from this session. Record a new session with the latest release, then try Evaluate again."
            case .tagNotFound(let version):
                "I couldn't find the source for Jarvis \(version) on GitHub. Try again after that release is published, or record a new session with the latest release."
            case .fetchFailed(let version):
                "I couldn't download the source for Jarvis \(version). I need an internet connection to fetch it. Connect to the internet and try Evaluate again."
            case .unpackFailed(let version):
                "I couldn't unpack the source for Jarvis \(version). Try Evaluate again. If it still fails, make sure your disk has free space."
            case .noAvailableSource:
                "I couldn't obtain Jarvis source for this evaluation. Connect to the internet and try again from an installed release."
            }
        }
    }

    public struct Checkout: Sendable {
        public let directory: URL
        public let version: String
        private let container: URL

        init(directory: URL, version: String, container: URL) {
            self.directory = directory
            self.version = version
            self.container = container
        }

        public func discard() { try? FileManager.default.removeItem(at: container) }
    }

    public typealias Fetcher = @Sendable (_ url: URL, _ destination: URL) async throws -> Void
    private let root: URL
    private let fetcher: Fetcher

    /// The temporary directory lets the OS reclaim a run that Quit abandoned mid-download.
    public init(root: URL = FileManager.default.temporaryDirectory,
                fetcher: @escaping Fetcher = ReleaseSourceStore.download) {
        self.root = root
        self.fetcher = fetcher
    }

    /// Falls back only when the session has no valid version or its tag is gone. A download failure
    /// never falls back: it would fail again and hide the recorded version from the error.
    public func fetch(version: String?, fallbackVersion: String?) async throws -> Checkout {
        let recorded = version.flatMap { EvaluationSource.isValidVersion($0) ? $0 : nil }
        let fallback = fallbackVersion.flatMap { EvaluationSource.isValidVersion($0) ? $0 : nil }
        if let recorded {
            do { return try await checkout(version: recorded) }
            catch Failure.tagNotFound(let missing) {
                guard let fallback, fallback != recorded else { throw Failure.tagNotFound(missing) }
                jlog("Jarvis: source tag v\(missing) is gone; evaluating against \(fallback)")
                return try await checkout(version: fallback)
            }
        }
        guard let fallback else { throw Failure.noAvailableSource }
        return try await checkout(version: fallback)
    }

    func checkout(version: String) async throws -> Checkout {
        guard EvaluationSource.isValidVersion(version) else { throw Failure.invalidVersion }
        try Task.checkCancellation()
        let manager = FileManager.default
        let container = root.appendingPathComponent("jarvis-source-\(UUID().uuidString)",
                                                    isDirectory: true)
        var complete = false
        defer { if !complete { try? manager.removeItem(at: container) } }
        do {
            try manager.createDirectory(at: container, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let archive = container.appendingPathComponent("source.tar.gz")
            let url = URL(string:
                "https://github.com/JINGBANZ/jarvis/archive/refs/tags/v\(version).tar.gz")!
            do {
                try await fetcher(url, archive)
            } catch {
                try Task.checkCancellation()
                jlog("Jarvis: source fetch for \(version) failed — \(error)")
                if (error as? URLError)?.code == .fileDoesNotExist {
                    throw Failure.tagNotFound(version)
                }
                throw Failure.fetchFailed(version)
            }
            try Task.checkCancellation()
            let extracted = container.appendingPathComponent("source", isDirectory: true)
            try manager.createDirectory(at: extracted, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            let output = try await AgentCLIProcessRunner.run(AgentCLIRun(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xzf", archive.path, "-C", extracted.path,
                            "--no-same-owner", "--no-same-permissions"], stdin: nil,
                workingDirectory: container, timeout: 60))
            guard output.exitCode == 0 else {
                jlog("Jarvis: source unpack for \(version) failed — \(output.stderr)")
                throw Failure.unpackFailed(version)
            }
            let directory = extracted.appendingPathComponent("jarvis-\(version)", isDirectory: true)
            guard manager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path)
            else { throw Failure.unpackFailed(version) }
            try Task.checkCancellation()
            complete = true
            return Checkout(directory: directory, version: version, container: container)
        } catch {
            try Task.checkCancellation()
            if let failure = error as? Failure { throw failure }
            jlog("Jarvis: source preparation for \(version) failed — \(error)")
            throw Failure.unpackFailed(version)
        }
    }

    public static func download(_ url: URL, to destination: URL) async throws {
        // Foundation's async download propagates task cancellation to URLSession's download task.
        let (temporary, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 404 { throw URLError(.fileDoesNotExist) }
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
