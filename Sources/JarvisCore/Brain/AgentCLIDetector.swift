import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Finds installed `claude` / `codex` CLIs and checks the local facts Jarvis needs before invoking
/// them. Binary discovery stays a pure filesystem probe. Bounded, non-billing local commands read
/// Claude's authoritative auth status and Codex's advertised feature names; Codex's auth file marker
/// remains authoritative.
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

    /// Run the blocking subprocess probes away from the caller's executor. Settings uses this path
    /// so a slow CLI cannot hold the main actor and delay or freeze its window.
    public func detectAllAsync() async -> [DetectedAgentCLI] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: detectAll())
            }
        }
    }

    /// The given provider's CLI, or nil when its binary isn't installed (or the provider is the
    /// direct API, which has nothing to detect).
    public func detect(_ provider: BrainProvider) -> DetectedAgentCLI? {
        guard let name = provider.cliExecutableName else { return nil }
        guard let url = firstExecutable(named: name) else { return nil }
        return DetectedAgentCLI(
            provider: provider,
            executableURL: url,
            authenticationStatus: authenticationStatus(provider, executable: url),
            supportedFeatures: provider == .codexCLI ? codexSupportedFeatures(executable: url) : []
        )
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

    /// Both probe documents are tiny. This is only a runaway-output backstop for a broken wrapper,
    /// and keeps the post-timeout pipe drain bounded in both time and memory.
    private static let maxProbeOutputBytes = 64 * 1_024

    /// Claude's own status command reads whichever credential store that installation uses and does
    /// not make a model request. A malformed result or timeout is `unknown`, never "signed out".
    private func claudeAuthenticationStatus(executable: URL) -> AgentCLIAuthenticationStatus {
        guard let output = runProbe(executable: executable,
                                    arguments: ["auth", "status", "--json"]),
              let status = try? JSONDecoder().decode(ClaudeAuthStatus.self, from: output.data)
        else { return .unknown }
        return status.loggedIn ? .signedIn : .signedOut
    }

    /// `--disable <feature>` rejects unknown names. Probe the installed binary's compiled feature
    /// registry so Jarvis passes only names that installation advertises. Failure falls back to no
    /// feature flags; the direct-response prompt, isolated project root, read-only sandbox, and short
    /// timeout still bound the call without making an older or renamed CLI unusable.
    private func codexSupportedFeatures(executable: URL) -> Set<String> {
        guard let output = runProbe(executable: executable, arguments: ["features", "list"]),
              output.status == 0,
              let text = String(data: output.data, encoding: .utf8)
        else { return [] }
        return Set(text.split(separator: "\n").compactMap { line in
            line.split(whereSeparator: \.isWhitespace).first.map(String.init)
        })
    }

    private struct ProbeOutput {
        let data: Data
        let status: Int32
    }

    /// Run one local, non-model status/capability command under the same bounded process policy for
    /// both CLIs. No API key is inherited, and stderr is irrelevant to the machine-readable probe.
    private func runProbe(executable: URL, arguments: [String]) -> ProbeOutput? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
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
        let data = Self.readAvailableOutput(stdout.fileHandleForReading,
                                            maxBytes: Self.maxProbeOutputBytes)
        return ProbeOutput(data: data, status: process.terminationStatus)
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
