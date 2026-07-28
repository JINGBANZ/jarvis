import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Finds installed `claude` / `codex` CLIs and checks the local facts Jarvis needs before invoking
/// them. Binary discovery stays a pure filesystem probe. Bounded, non-billing local commands read
/// Claude's authoritative auth status, each CLI's basic MCP help, and Codex's enabled feature
/// registry; Codex's auth file marker remains authoritative.
public struct AgentCLIDetector: Sendable {
    private let home: URL
    private let pathVariable: String?
    private let authStatusTimeout: TimeInterval
    private let temporaryDirectory: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                pathVariable: String? = ProcessInfo.processInfo.environment["PATH"],
                authStatusTimeout: TimeInterval = 2,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.home = home
        self.pathVariable = pathVariable
        self.authStatusTimeout = authStatusTimeout
        self.temporaryDirectory = temporaryDirectory
    }

    /// All CLI providers found on this machine, in `BrainProvider` declaration order.
    public func detectAll() -> [DetectedAgentCLI] {
        detectAll(BrainProvider.allCases)
    }

    /// Only the requested CLI providers, in first-occurrence order. Duplicate providers are probed
    /// once, and direct API providers are ignored because they have no local executable.
    public func detectAll(_ providers: [BrainProvider]) -> [DetectedAgentCLI] {
        var seen = Set<BrainProvider>()
        return providers
            .filter { seen.insert($0).inserted }
            .compactMap { detect($0) }
    }

    /// Run the blocking subprocess probes away from the caller's executor. Settings uses this path
    /// so a slow CLI cannot hold the main actor and delay or freeze its window.
    public func detectAllAsync() async -> [DetectedAgentCLI] {
        await detectAllAsync(BrainProvider.allCases)
    }

    /// Probe only the requested providers away from the caller's executor. Startup uses this path
    /// so an unrelated installed CLI cannot delay a route that will never invoke it.
    public func detectAllAsync(_ providers: [BrainProvider]) async -> [DetectedAgentCLI] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: detectAll(providers))
            }
        }
    }

    /// Find only the first usable provider in the supplied order, off the caller's executor. Agentic
    /// evaluation uses this instead of probing a second CLI that it will not invoke.
    public func detectFirstAsync(_ providers: [BrainProvider]) async -> DetectedAgentCLI? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: providers.lazy.compactMap(detect).first)
            }
        }
    }

    /// The given provider's CLI, or nil when its binary isn't installed (or the provider is the
    /// direct API, which has nothing to detect).
    public func detect(_ provider: BrainProvider) -> DetectedAgentCLI? {
        guard let name = provider.cliExecutableName else { return nil }
        guard let url = firstExecutable(named: name) else { return nil }
        let codexFeaturesToDisable = provider == .codexCLI
            ? codexFeaturesToDisable(executable: url)
            : []
        return DetectedAgentCLI(
            provider: provider,
            executableURL: url,
            authenticationStatus: authenticationStatus(provider, executable: url),
            codexFeaturesToDisable: codexFeaturesToDisable,
            supportsMCP: supportsMCP(provider, executable: url)
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

    /// Stable $PATH entries first, then common install locations. Apps opened from a terminal inherit
    /// that terminal's PATH, which can contain short-lived launcher wrappers under the system temp
    /// directory. A long-running app must not retain one of those paths after its owner exits.
    private func firstExecutable(named name: String) -> URL? {
        let dirs = Self.stableSearchDirectories(
            pathVariable: pathVariable,
            home: home,
            temporaryDirectory: temporaryDirectory
        )
        for dir in dirs where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
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

    /// Codex has no global built-in-tool allowlist. Quiesce every feature this exact installation
    /// reports as enabled unless the registry marks it removed; this makes newly advertised surfaces
    /// default off without maintaining a version-specific feature-name list. Any probe or parse
    /// failure returns an empty set, retaining the prompt/read-only/ephemeral restrictions and
    /// acknowledged-terminal completion rather than guessing.
    private func codexFeaturesToDisable(executable: URL) -> Set<String> {
        guard let output = runProbe(executable: executable, arguments: ["features", "list"]),
              output.status == 0,
              output.data.count < Self.maxProbeOutputBytes,
              let text = String(data: output.data, encoding: .utf8)
        else { return [] }

        var result = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3,
                  Self.isSafeCodexFeatureName(fields[0]),
                  let enabled = Self.codexFeatureState(fields.last!)
            else { return [] }

            let stage = fields.dropFirst().dropLast().joined(separator: " ")
            guard !stage.isEmpty else { return [] }
            if enabled && stage != "removed" {
                result.insert(String(fields[0]))
            }
        }
        return result
    }

    private static func codexFeatureState(_ value: Substring) -> Bool? {
        switch value {
        case "true": true
        case "false": false
        default: nil
        }
    }

    /// Feature names are passed as a separate argv value, but accepting only the CLI's current ASCII
    /// identifier shape also prevents malformed help text from becoming invocation configuration.
    private static func isSafeCodexFeatureName(_ value: Substring) -> Bool {
        let bytes = value.utf8
        guard let first = bytes.first, isASCIIAlphanumeric(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            isASCIIAlphanumeric($0) || $0 == 95 || $0 == 45
        }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || (65...90).contains(byte) || (48...57).contains(byte)
    }

    /// Capability comes from the installed binary, never its version string. Missing or unfamiliar
    /// help output makes that installation unavailable for coaching instead of guessing flags.
    private func supportsMCP(
        _ provider: BrainProvider,
        executable: URL
    ) -> Bool {
        let arguments: [String]
        switch provider {
        case .claudeCode:
            arguments = ["--help"]
        case .codexCLI:
            arguments = ["mcp", "--help"]
        case .openAI:
            return false
        }
        guard let output = runProbe(executable: executable, arguments: arguments),
              output.status == 0,
              let text = String(data: output.data, encoding: .utf8) else {
            return false
        }
        switch provider {
        case .claudeCode:
            return text.contains("--mcp-config") && text.contains("--strict-mcp-config")
        case .codexCLI:
            return text.localizedCaseInsensitiveContains("mcp")
        case .openAI:
            return false
        }
    }

    private struct ProbeOutput {
        let data: Data
        let status: Int32
    }

    /// The lock protects the stop flag and bounded retained prefix; the background reader is the
    /// only descriptor consumer, so this POSIX edge can safely cross the reader-thread boundary.
    private final class ProbeOutputDrain: @unchecked Sendable {
        private let lock = NSLock()
        private let maxBytes: Int
        private var stopped = false
        private var storage = Data()

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func run(descriptor: Int32) {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0,
                  fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                return
            }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                lock.lock()
                let isStopped = stopped
                lock.unlock()

                var state = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0)
                let result = poll(&state, 1, isStopped ? 0 : 25)
                if result == 0 {
                    if isStopped { return }
                    continue
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard state.revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0
                else { continue }

                let count = read(descriptor, &buffer, buffer.count)
                if count == 0 { return }
                guard count > 0 else {
                    if errno == EINTR {
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        if isStopped { return }
                        continue
                    }
                    return
                }

                lock.lock()
                let retained = min(Int(count), max(0, maxBytes - storage.count))
                if retained > 0 {
                    storage.append(contentsOf: buffer.prefix(retained))
                }
                // Once the parent exits, drain only the bounded prefix. This preserves output that
                // was already split across pipe reads without following an inherited writer forever.
                let shouldStop = stopped && storage.count >= maxBytes
                lock.unlock()
                if shouldStop { return }
            }
        }
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

        // Drain while the child runs, retaining only the bounded prefix. Waiting for exit before
        // reading can deadlock a valid CLI whose help output fills the pipe buffer.
        let readHandle = stdout.fileHandleForReading
        let drain = ProbeOutputDrain(maxBytes: Self.maxProbeOutputBytes)
        let drainFinished = DispatchSemaphore(value: 0)
        let drainThread = Thread {
            drain.run(descriptor: readHandle.fileDescriptor)
            drainFinished.signal()
        }
        drainThread.name = "Jarvis CLI probe output"
        drainThread.start()
        try? stdout.fileHandleForWriting.close()

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
        drain.stop()
        drainFinished.wait()
        try? readHandle.close()
        return ProbeOutput(data: drain.data, status: process.terminationStatus)
    }
}
