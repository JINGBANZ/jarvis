import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Finds installed `claude` / `codex` CLIs for the session evaluator and checks whether each is
/// signed in. Binary discovery stays a pure filesystem probe. Claude's sign-in state comes from its
/// bounded, non-billing status command; Codex's auth file marker remains authoritative.
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

    /// The requested CLIs that are installed, in first-occurrence order, probed away from the
    /// caller's executor so a slow status command cannot hold it. A CLI named twice is probed once.
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

    /// The given CLI, or nil when its binary isn't installed.
    public func detect(_ cli: AgentCLI) -> DetectedAgentCLI? {
        guard let url = firstExecutable(for: cli) else { return nil }
        return DetectedAgentCLI(
            cli: cli,
            executableURL: url,
            authenticationStatus: authenticationStatus(cli, executable: url))
    }

    /// The common install locations consulted after $PATH — the single source of truth, also used
    /// by `AgentCLIProcessRunner` to seed the subprocess PATH: a CLI *found* in one of these dirs
    /// may need its interpreter or helpers from another (an npm-shim `claude` whose
    /// `/usr/bin/env node` lives in `/opt/homebrew/bin`), so detection and execution must see the
    /// same directories or detection succeeds while every launch fails.
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

    /// Stable $PATH entries first, then common install locations. Apps opened from a terminal inherit
    /// that terminal's PATH, which can contain short-lived launcher wrappers under the system temp
    /// directory. A long-running app must not retain one of those paths after its owner exits.
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

    /// Search/environment PATH shared by detection and execution. Only inherited entries under the
    /// system temporary directory are discarded; explicit user and system install locations retain
    /// their normal precedence and are appended as fallbacks.
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

    /// The status document is tiny. This is only a runaway-output backstop for a broken wrapper, and
    /// keeps the post-timeout pipe drain bounded in both time and memory.
    private static let maxProbeOutputBytes = 64 * 1_024

    /// Claude's own status command reads whichever credential store that installation uses and does
    /// not make a model request. A malformed result or timeout is `unknown`, never "signed out".
    private func claudeAuthenticationStatus(executable: URL) -> AgentCLIAuthenticationStatus {
        guard let output = runProbe(executable: executable,
                                    arguments: ["auth", "status", "--json"]),
              let status = try? JSONDecoder().decode(ClaudeAuthStatus.self, from: output)
        else { return .unknown }
        return status.loggedIn ? .signedIn : .signedOut
    }

    /// Run one local, non-model status command under a bounded process policy. No API key is
    /// inherited, and stderr is irrelevant to the machine-readable probe.
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

        // `Process` termination callbacks can be delayed while the test runner or app is busy.
        // Wait for the child directly and bound that wait with pid-only watchdogs, matching the
        // production CLI runner without capturing the non-Sendable Process in GCD closures.
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

    /// Drain only bytes already available after the wrapper exits. A wrapper may leave a child
    /// holding the inherited stdout pipe open; a blocking `readDataToEndOfFile()` would then defeat
    /// the process watchdog while waiting for that unrelated child to close its writer.
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
