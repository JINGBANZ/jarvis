import Foundation

/// Source of an API credential. An owner-only file is primary (spec §5); env is a headless fallback.
public protocol SecretStore {
    func apiKey(for credential: Credential) -> String?
}

/// Reads each credential's environment variable from a provided dictionary (defaults to process env).
public struct EnvSecretStore: SecretStore {
    private let environment: [String: String]
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }
    public func apiKey(for credential: Credential) -> String? {
        guard let v = environment[credential.environmentVariable], !v.isEmpty else { return nil }
        return v
    }
}

/// Reads/writes each credential in its own owner-only file under one Application Support directory.
///
/// We deliberately do *not* use the login Keychain. macOS keys Keychain access to a per-build code
/// *partition* (a cdhash, for a self-signed app with no Apple Team ID), so a fresh build is treated as
/// a new program and re-prompts for the login password on every rebuild — unlike TCC (mic/screen),
/// which keys to the stable signing identity and persists. A 0600 file in a 0700 directory has the
/// same practical trust boundary as the headless environment fallback (any process running as this
/// user can read it) but never prompts and survives every rebuild.
public struct FileSecretStore: SecretStore {
    /// Directory holding every credential file. Exposed because callers also derive sibling
    /// Jarvis-managed paths (for example the sessions directory) from it.
    public let directoryURL: URL

    /// Defaults to `~/Library/Application Support/Jarvis/`. Pass an explicit URL in tests.
    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directoryURL = base.appendingPathComponent("Jarvis", isDirectory: true)
        }
    }

    /// Absolute path of one credential's file.
    public func fileURL(for credential: Credential) -> URL {
        directoryURL.appendingPathComponent(credential.fileName)
    }

    public func apiKey(for credential: Credential) -> String? {
        guard let data = try? Data(contentsOf: fileURL(for: credential)),
              let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    public func setApiKey(_ key: String, for credential: Credential) -> Bool {
        let fm = FileManager.default
        // 0700 dir: a 0755 parent would leak the credential files' names/metadata to other local
        // users (CWE-732). Mirrors how the per-session log directory is created.
        do {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // createDirectory only applies the mode to directories it *creates*; a pre-existing dir
            // (e.g. a 0755 left by a restored backup or another tool) keeps its mode. Tighten it so the
            // owner-only guarantee holds regardless. Best-effort: a metadata-perms failure must not
            // block saving the key, whose own bytes are still protected 0600.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        } catch { return false }
        // Create the file 0600 from the start (createFile applies attributes atomically on creation),
        // so the secret is never briefly world-readable between write and chmod.
        return fm.createFile(atPath: fileURL(for: credential).path, contents: Data(key.utf8),
                             attributes: [.posixPermissions: 0o600])
    }
}

/// Tries each store in order for the requested credential; first non-nil wins. App uses [File, Env].
public struct ChainedSecretStore: SecretStore {
    private let stores: [SecretStore]
    public init(_ stores: [SecretStore]) { self.stores = stores }
    public func apiKey(for credential: Credential) -> String? {
        for s in stores { if let k = s.apiKey(for: credential) { return k } }
        return nil
    }
}
