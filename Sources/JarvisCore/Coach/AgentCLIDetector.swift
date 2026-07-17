import Foundation

/// A locally installed coding-agent CLI usable as a brain provider.
public struct DetectedAgentCLI: Sendable, Equatable {
    public let provider: BrainProvider
    public let executableURL: URL
    /// Best-effort "signed in" check from the CLI's on-disk auth markers. A false negative is
    /// possible (e.g. Claude Code storing credentials only in the Keychain), so callers should treat
    /// this as a hint for the UI, never as a hard gate.
    public let authenticated: Bool

    public init(provider: BrainProvider, executableURL: URL, authenticated: Bool) {
        self.provider = provider
        self.executableURL = executableURL
        self.authenticated = authenticated
    }
}

/// Finds installed `claude` / `codex` CLIs by probing the filesystem — no subprocess is spawned, so
/// detection is instant and safe to run every time the Settings tab opens. Pure file checks behind an
/// injectable `Probe` keep it unit-testable on any machine.
public struct AgentCLIDetector: Sendable {
    /// The filesystem view, injectable for tests. Defaults to the real FileManager.
    public struct Probe: Sendable {
        public let isExecutableFile: @Sendable (String) -> Bool
        public let fileExists: @Sendable (String) -> Bool
        public let readFile: @Sendable (String) -> String?

        public init(isExecutableFile: @escaping @Sendable (String) -> Bool,
                    fileExists: @escaping @Sendable (String) -> Bool,
                    readFile: @escaping @Sendable (String) -> String?) {
            self.isExecutableFile = isExecutableFile
            self.fileExists = fileExists
            self.readFile = readFile
        }

        public static let real = Probe(
            isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            readFile: { try? String(contentsOfFile: $0, encoding: .utf8) })
    }

    private let home: URL
    private let pathVariable: String?
    private let probe: Probe

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                pathVariable: String? = ProcessInfo.processInfo.environment["PATH"],
                probe: Probe = .real) {
        self.home = home
        self.pathVariable = pathVariable
        self.probe = probe
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
                                authenticated: isAuthenticated(provider))
    }

    /// $PATH first, then the common install locations. The fallbacks matter because the app is
    /// launched via `open` and inherits launchd's minimal PATH (`/usr/bin:/bin:…`), which contains
    /// none of the places these CLIs actually install to.
    private func firstExecutable(named name: String) -> URL? {
        var dirs = (pathVariable ?? "").split(separator: ":").map(String.init)
        dirs += [
            home.appendingPathComponent(".claude/local").path,   // claude's self-managed install
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".cargo/bin").path,       // codex's rust install
        ]
        for dir in dirs where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if probe.isExecutableFile(candidate.path) { return candidate }
        }
        return nil
    }

    /// On-disk auth markers per CLI. Claude Code writes `~/.claude/.credentials.json` where no
    /// Keychain is available and records the OAuth account in `~/.claude.json`; Codex keeps its
    /// ChatGPT-login token in `~/.codex/auth.json`. Deliberately NOT probed via the Keychain
    /// (`security` can trigger a password prompt) or by running the CLI (slow, may bill a request).
    private func isAuthenticated(_ provider: BrainProvider) -> Bool {
        switch provider {
        case .openAI:
            return false
        case .claudeCode:
            if probe.fileExists(home.appendingPathComponent(".claude/.credentials.json").path) { return true }
            let settings = probe.readFile(home.appendingPathComponent(".claude.json").path)
            return settings?.contains("\"oauthAccount\"") == true
        case .codexCLI:
            return probe.fileExists(home.appendingPathComponent(".codex/auth.json").path)
        }
    }
}
