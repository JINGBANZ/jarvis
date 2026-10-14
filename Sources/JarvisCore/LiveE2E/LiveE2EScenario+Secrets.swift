#if JARVIS_LIVE_E2E
import Foundation

extension LiveE2EScenario {
    public func makeInvalidKeyDirectory(
        at directory: URL, using source: any SecretStore = FileSecretStore()
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let store = FileSecretStore(directoryURL: directory)
        for credential in requiredCredentials.subtracting([.openAIAPIKey]) {
            guard let key = source.apiKey(for: credential) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            guard store.setApiKey(key, for: credential) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard store.setApiKey("sk-jarvis-live-e2e-invalid-key", for: .openAIAPIKey) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return directory
    }
}
#endif
