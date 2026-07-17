import Foundation

/// Finds installed `claude` / `codex` CLIs by probing the filesystem — no subprocess is spawned, so
/// detection is instant and safe to run every time the Settings tab opens. The home directory and
/// PATH are injectable (tests point them at a fixture directory, mirroring how `BrainPreferences`
/// takes a `UserDefaults(suiteName:)`); the file checks themselves are the real FileManager.
public struct AgentCLIDetector: Sendable {
    private let home: URL
    private let pathVariable: String?

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                pathVariable: String? = ProcessInfo.processInfo.environment["PATH"]) {
        self.home = home
        self.pathVariable = pathVariable
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

    /// On-disk auth markers per CLI. Claude Code writes `~/.claude/.credentials.json` where no
    /// Keychain is available and records the OAuth account in `~/.claude.json`; Codex keeps its
    /// ChatGPT-login token in `~/.codex/auth.json`. Deliberately NOT probed via the Keychain
    /// (`security` can trigger a password prompt) or by running the CLI (slow, may bill a request).
    private func isAuthenticated(_ provider: BrainProvider) -> Bool {
        let fm = FileManager.default
        switch provider {
        case .openAI:
            return false
        case .claudeCode:
            if fm.fileExists(atPath: home.appendingPathComponent(".claude/.credentials.json").path) {
                return true
            }
            let settings = try? String(contentsOf: home.appendingPathComponent(".claude.json"),
                                       encoding: .utf8)
            return settings?.contains("\"oauthAccount\"") == true
        case .codexCLI:
            return fm.fileExists(atPath: home.appendingPathComponent(".codex/auth.json").path)
        }
    }
}
