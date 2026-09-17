import Foundation

public protocol SecretStore {
    func apiKey(for credential: Credential) -> String?
}

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

/// Deliberately not the Keychain: a self-signed app's Keychain access is keyed to each build's
/// cdhash, so every rebuild re-prompts for the login password. A 0600 file in a 0700 directory has
/// the same trust boundary as the environment fallback.
public struct FileSecretStore: SecretStore {
    public let directoryURL: URL

    /// Nil means `~/Library/Application Support/Jarvis/`.
    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directoryURL = base.appendingPathComponent("Jarvis", isDirectory: true)
        }
    }

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
        // 0700 so other local users can't list credential file names (CWE-732).
        do {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // createDirectory leaves an existing directory's mode alone. Best-effort: the key file
            // itself is still 0600.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        } catch { return false }
        // createFile applies 0600 at creation, so the secret is never briefly world-readable.
        return fm.createFile(atPath: fileURL(for: credential).path, contents: Data(key.utf8),
                             attributes: [.posixPermissions: 0o600])
    }
}

public struct ChainedSecretStore: SecretStore {
    private let stores: [SecretStore]
    public init(_ stores: [SecretStore]) { self.stores = stores }
    public func apiKey(for credential: Credential) -> String? {
        for s in stores { if let k = s.apiKey(for: credential) { return k } }
        return nil
    }
}
