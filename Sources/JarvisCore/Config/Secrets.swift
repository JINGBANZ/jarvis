import Foundation
import Security

/// Source of the OpenAI API key. Keychain is primary (spec §5); env is a headless fallback.
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

/// Reads/writes the key in the macOS login Keychain as a generic password.
public struct KeychainSecretStore: SecretStore {
    private let service: String
    private let account: String
    public init(service: String = "com.jarvis.coach", account: String = "openai-api-key") {
        self.service = service
        self.account = account
    }

    public func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    public func setApiKey(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        // Explicit: readable only while unlocked, and never synced to iCloud Keychain.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Tries each store in order; first non-nil wins. App uses [Keychain, Env].
public struct ChainedSecretStore: SecretStore {
    private let stores: [SecretStore]
    public init(_ stores: [SecretStore]) { self.stores = stores }
    public func apiKey() -> String? {
        for s in stores { if let k = s.apiKey() { return k } }
        return nil
    }
}
