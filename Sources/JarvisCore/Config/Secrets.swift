import Foundation

/// Source of the OpenAI API key. An owner-only file is primary (spec §5); env is a headless fallback.
public protocol SecretStore {
    func apiKey() -> String?
}

/// Reads OPENAI_API_KEY from a provided environment dictionary (defaults to the process env).
public struct EnvSecretStore: SecretStore {
    private let environment: [String: String]
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }
    public func apiKey() -> String? {
        guard let v = environment["OPENAI_API_KEY"], !v.isEmpty else { return nil }
        return v
    }
}

/// Reads/writes the key in an owner-only file under Application Support.
///
/// We deliberately do *not* use the login Keychain. macOS keys Keychain access to a per-build code
/// *partition* (a cdhash, for a self-signed app with no Apple Team ID), so a fresh build is treated as
/// a new program and re-prompts for the login password on every rebuild — unlike TCC (mic/screen),
/// which keys to the stable signing identity and persists. A 0600 file in a 0700 directory has the
/// same practical trust boundary as the headless `OPENAI_API_KEY` fallback (any process running as
/// this user can read it) but never prompts and survives every rebuild.
public struct FileSecretStore: SecretStore {
    /// Absolute path of the credential file. Exposed so callers/tests can see where the key lives.
    public let fileURL: URL

    /// Defaults to `~/Library/Application Support/Jarvis/openai-api-key`. Pass an explicit URL in tests.
    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.fileURL = base.appendingPathComponent("Jarvis", isDirectory: true)
                .appendingPathComponent("openai-api-key")
        }
    }

    public func apiKey() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    public func setApiKey(_ key: String) -> Bool {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        // 0700 dir: a 0755 parent would leak the credential file's name/metadata to other local users
        // (CWE-732). Mirrors how the dev-mode log directory is created.
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch { return false }
        // Create the file 0600 from the start (createFile applies attributes atomically on creation),
        // so the secret is never briefly world-readable between write and chmod.
        return fm.createFile(atPath: fileURL.path, contents: Data(key.utf8),
                             attributes: [.posixPermissions: 0o600])
    }
}

/// Tries each store in order; first non-nil wins. App uses [File, Env].
public struct ChainedSecretStore: SecretStore {
    private let stores: [SecretStore]
    public init(_ stores: [SecretStore]) { self.stores = stores }
    public func apiKey() -> String? {
        for s in stores { if let k = s.apiKey() { return k } }
        return nil
    }
}
