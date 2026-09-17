import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct AgentCLIDetector: Sendable {
    private let home: URL
    private let pathVariable: String?
    private let applicationDirectories: [URL]
    private let authStatusTimeout: TimeInterval
    private let temporaryDirectory: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                pathVariable: String? = ProcessInfo.processInfo.environment["PATH"],
                authStatusTimeout: TimeInterval = 2,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                applicationDirectories: [URL]? = nil) {
        self.home = home
        self.applicationDirectories = applicationDirectories ?? [
            home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications"),
        ]
        self.pathVariable = pathVariable
        self.authStatusTimeout = authStatusTimeout
        self.temporaryDirectory = temporaryDirectory
    }

    /// Probed off the caller's executor so a slow status command cannot hold it.
    public func detectAllAsync(_ clis: [AgentCLI]) async -> [DetectedAgentCLI] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var seen = Set<AgentCLI>()
                continuation.resume(returning: clis
                    .filter { seen.insert($0).inserted }
                    .compactMap { detect($0) })
            }
        }
    }

    public func detect(_ cli: AgentCLI) -> DetectedAgentCLI? {
        guard let url = firstExecutable(for: cli) else { return nil }
        return DetectedAgentCLI(
            cli: cli,
            executableURL: url,
            authenticationStatus: authenticationStatus(cli, executable: url))
    }

    /// Also seeds the runner's PATH: an npm-shim `claude` may need `node` from another directory,
    /// so detection and execution must see the same list.
    static func fallbackDirectories(home: URL) -> [String] {
        [
            home.appendingPathComponent(".claude/local").path,   // claude's self-managed install
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".cargo/bin").path,       // codex's rust install
        ] + nvmDirectories(home: home)
    }

    private func firstExecutable(for cli: AgentCLI) -> URL? {
        let dirs = Self.stableSearchDirectories(
            pathVariable: pathVariable,
            home: home,
            temporaryDirectory: temporaryDirectory
        )
        let bundled = cli == .codex ? applicationDirectories.flatMap { directory in
            ["Codex.app", "ChatGPT.app"].map {
                directory.appendingPathComponent("\($0)/Contents/Resources").path
            }
        } : []
        for dir in dirs + bundled where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(cli.executableName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Drops inherited entries under the temp directory: a terminal-launched app inherits
    /// short-lived launcher wrappers there, which must not outlive their owner.
    static func stableSearchDirectories(pathVariable: String?, home: URL,
                                        temporaryDirectory: URL) -> [String] {
        let inherited = (pathVariable ?? "").split(separator: ":").map(String.init)
            .filter { !isInside(URL(fileURLWithPath: $0), root: temporaryDirectory) }
        var seen = Set<String>()
        return (inherited + fallbackDirectories(home: home)).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func authenticationStatus(_ cli: AgentCLI, executable: URL)
        -> AgentCLIAuthenticationStatus {
        switch cli {
        case .claude:
            return claudeAuthenticationStatus(executable: executable)
        case .codex:
            return FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".codex/auth.json").path
            ) ? .signedIn : .signedOut
        }
    }

    private struct ClaudeAuthStatus: Decodable {
        let loggedIn: Bool
    }

    /// Only a runaway-output backstop for a broken wrapper; the status document is tiny.
    private static let maxProbeOutputBytes = 64 * 1_024

    /// Makes no model request. A malformed result or timeout is `unknown`, never signed out.
    private func claudeAuthenticationStatus(executable: URL) -> AgentCLIAuthenticationStatus {
        guard let output = runProbe(executable: executable,
                                    arguments: ["auth", "status", "--json"]),
              let status = try? JSONDecoder().decode(ClaudeAuthStatus.self, from: output)
        else { return .unknown }
        return status.loggedIn ? .signedIn : .signedOut
    }

    private func runProbe(executable: URL, arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        let searchDirectories = Self.stableSearchDirectories(
            pathVariable: pathVariable,
            home: home,
            temporaryDirectory: temporaryDirectory
        )
        environment["PATH"] = ([executable.deletingLastPathComponent().path] + searchDirectories)
            .joined(separator: ":")
        environment.removeValue(forKey: "OPENAI_API_KEY")
        process.environment = environment

        do {
            try process.run()
        } catch {
            return nil
        }

        // `Process` termination callbacks can be delayed while the app is busy, so wait directly
        // and bound the wait with pid-only watchdogs.
        let pid = process.processIdentifier
        let timeout = max(0.01, authStatusTimeout)
        let terminator = DispatchWorkItem { kill(pid, SIGTERM) }
        let killer = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: terminator)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 1, execute: killer)
        process.waitUntilExit()
        terminator.cancel()
        killer.cancel()
        return Self.readAvailableOutput(stdout.fileHandleForReading, maxBytes: Self.maxProbeOutputBytes)
    }

    /// Non-blocking: a wrapper's child may still hold stdout open, and `readDataToEndOfFile()`
    /// would wait on it past the watchdog.
    private static func readAvailableOutput(_ handle: FileHandle, maxBytes: Int) -> Data {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            try? handle.close()
            return Data()
        }
        defer { try? handle.close() }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while output.count < maxBytes {
            let capacity = min(buffer.count, maxBytes - output.count)
            let count = read(descriptor, &buffer, capacity)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(Int(count)))
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            return Data()
        }
        return output
    }
}
