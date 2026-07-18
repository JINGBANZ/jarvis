import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Finds installed `claude` / `codex` CLIs and checks their sign-in state. Binary discovery stays a
/// pure filesystem probe. Claude authentication comes from its non-billing `auth status --json`
/// command because its on-disk account marker can survive an expired OAuth session; the command is
/// bounded so Settings cannot hang on a broken CLI. Codex's auth file remains authoritative.
public struct AgentCLIDetector: Sendable {
    private let home: URL
    private let pathVariable: String?
    private let authStatusTimeout: TimeInterval

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                pathVariable: String? = ProcessInfo.processInfo.environment["PATH"],
                authStatusTimeout: TimeInterval = 2) {
        self.home = home
        self.pathVariable = pathVariable
        self.authStatusTimeout = authStatusTimeout
    }

    /// All CLI providers found on this machine, in `BrainProvider` declaration order.
    public func detectAll() -> [DetectedAgentCLI] {
        BrainProvider.allCases.compactMap(detect)
    }

    /// The given provider's CLI, or nil when its binary isn't installed (or the provider is the
    /// direct API, which has nothing to detect).
    public func detect(_ provider: BrainProvider) -> DetectedAgentCLI? {
        guard let name = provider.cliExecutableName else { return nil }
        guard let url = firstExecutable(named: name) else { return nil }
        return DetectedAgentCLI(provider: provider, executableURL: url,
                                authenticationStatus: authenticationStatus(provider, executable: url))
    }

    /// The common install locations consulted after $PATH — the single source of truth, also used
    /// by `AgentCLIProcessRunner` to seed the subprocess PATH: a CLI *found* in one of these dirs
    /// may need its interpreter or helpers from another (an npm-shim `claude` whose
    /// `/usr/bin/env node` lives in `/opt/homebrew/bin`), so detection and execution must see the
    /// same directories or Settings says "detected" while every spawned turn fails.
    static func fallbackDirectories(home: URL) -> [String] {
        [
            home.appendingPathComponent(".claude/local").path,   // claude's self-managed install
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".cargo/bin").path,       // codex's rust install
        ]
    }

    /// $PATH first, then the common install locations. The fallbacks matter because the app is
    /// launched via `open` and inherits launchd's minimal PATH (`/usr/bin:/bin:…`), which contains
    /// none of the places these CLIs actually install to.
    private func firstExecutable(named name: String) -> URL? {
        let dirs = (pathVariable ?? "").split(separator: ":").map(String.init)
            + Self.fallbackDirectories(home: home)
        for dir in dirs where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func authenticationStatus(_ provider: BrainProvider, executable: URL)
        -> AgentCLIAuthenticationStatus {
        switch provider {
        case .openAI:
            return .unknown
        case .claudeCode:
            return claudeAuthenticationStatus(executable: executable)
        case .codexCLI:
            return FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".codex/auth.json").path
            ) ? .signedIn : .signedOut
        }
    }

    private struct ClaudeAuthStatus: Decodable {
        let loggedIn: Bool
    }

    /// Claude's own status command reads whichever credential store that installation uses and does
    /// not make a model request. A malformed result or timeout is `unknown`, never "signed out".
    private func claudeAuthenticationStatus(executable: URL) -> AgentCLIAuthenticationStatus {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "status", "--json"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        let extraDirectories = [executable.deletingLastPathComponent().path]
            + Self.fallbackDirectories(home: home)
        environment["PATH"] = ([pathVariable].compactMap { $0 } + extraDirectories)
            .joined(separator: ":")
        environment.removeValue(forKey: "OPENAI_API_KEY")
        process.environment = environment

        do {
            try process.run()
        } catch {
            return .unknown
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
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let status = try? JSONDecoder().decode(ClaudeAuthStatus.self, from: data) else {
            return .unknown
        }
        return status.loggedIn ? .signedIn : .signedOut
    }
}
