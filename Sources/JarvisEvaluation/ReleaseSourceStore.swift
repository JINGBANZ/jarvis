import Foundation
import JarvisCore
import JarvisBrainProviders

/// Public release source only. Staging and publication share a volume so incomplete trees never
/// become cache hits. Session artifacts are never copied here.
public struct ReleaseSourceStore: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case invalidVersion
        case tagNotFound(String)
        case fetchFailed(String)
        case cacheFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidVersion:
                "I can't read a valid Jarvis version from this session. Record a new session with the latest release, then try Evaluate again."
            case .tagNotFound(let version):
                "I couldn't find the source for Jarvis \(version) on GitHub. Try again after that release is published, or record a new session with the latest release."
            case .fetchFailed(let version):
                "I couldn't download the source for Jarvis \(version). I need an internet connection to fetch it. Connect to the internet and try Evaluate again."
            case .cacheFailed(let version):
                "I couldn't unpack or save the source for Jarvis \(version). Try Evaluate again. If it still fails, make sure your Application Support folder is writable and your disk has free space."
            }
        }
    }

    public typealias Fetcher = @Sendable (_ url: URL, _ destination: URL) async throws -> Void
    private let root: URL
    private let fetcher: Fetcher

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Jarvis/source"),
                fetcher: @escaping Fetcher = ReleaseSourceStore.download) {
        self.root = root
        self.fetcher = fetcher
    }

    public func directory(for version: String) async throws -> URL {
        guard EvaluationSource.isValidVersion(version) else { throw Failure.invalidVersion }
        try Task.checkCancellation()
        let manager = FileManager.default
        let destination = root.appendingPathComponent("v\(version)", isDirectory: true)
        let innerPath = "jarvis-\(version)"
        let checkout = destination.appendingPathComponent(innerPath, isDirectory: true)
        let staging = root.appendingPathComponent(".fetch-\(UUID().uuidString)")
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            if manager.fileExists(atPath: checkout.appendingPathComponent("Package.swift").path) {
                try touch(destination)
                return checkout
            }
            try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: staging) }
            let archive = staging.appendingPathComponent("source.tar.gz")
            let url = URL(string: "https://github.com/JINGBANZ/jarvis/archive/refs/tags/v\(version).tar.gz")!
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
            let extracted = staging.appendingPathComponent("extracted")
            try manager.createDirectory(at: extracted, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            let output = try await AgentCLIProcessRunner.run(AgentCLIRun(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xzf", archive.path, "-C", extracted.path,
                            "--no-same-owner", "--no-same-permissions"], stdin: nil,
                workingDirectory: staging, timeout: 60))
            guard output.exitCode == 0 else {
                jlog("Jarvis: source unpack for \(version) failed — \(output.stderr)")
                throw Failure.cacheFailed(version)
            }
            guard manager.fileExists(atPath: extracted.appendingPathComponent(innerPath)
                .appendingPathComponent("Package.swift").path) else {
                throw Failure.cacheFailed(version)
            }
            try Task.checkCancellation()
            // A missing sentinel can only be a damaged old cache; discard it after a complete
            // replacement is ready. Another evaluator may have published this version meanwhile.
            if !manager.fileExists(atPath: checkout.appendingPathComponent("Package.swift").path) {
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                try manager.moveItem(at: extracted, to: destination)
            }
            try touch(destination)
            try prune()
            return checkout
        } catch {
            try Task.checkCancellation()
            if let failure = error as? Failure { throw failure }
            jlog("Jarvis: source cache for \(version) failed — \(error)")
            throw Failure.cacheFailed(version)
        }
    }

    private func touch(_ directory: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: directory.path)
    }

    private func prune() throws {
        let versions = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
            .filter { url in
                url.lastPathComponent.hasPrefix("v")
                    && EvaluationSource.isValidVersion(String(url.lastPathComponent.dropFirst()))
                    && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted {
                let lhs = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let rhs = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (lhs ?? .distantPast) > (rhs ?? .distantPast)
            }
        for old in versions.dropFirst(3) { try FileManager.default.removeItem(at: old) }
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
