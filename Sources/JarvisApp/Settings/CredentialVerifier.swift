import Foundation
import JarvisCore

/// One cheap request per saved key, so a bad key, a blocked region, or a dead network shows up in
/// Settings rather than after the first coaching session dies in silence.
///
/// A models-list call is the smallest request both vendors answer without spending inference. Both
/// take the key in a header; Gemini's `x-goog-api-key` is used in place of the `key` query parameter
/// the Live socket needs, so the secret never enters a URL here.
struct CredentialVerifier: Sendable {
    private static let timeout: TimeInterval = 10

    func check(_ credential: Credential, key: String) async -> CredentialCheck.Verdict {
        var request: URLRequest
        switch credential {
        case .openAIAPIKey:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .geminiAPIKey:
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        request.timeoutInterval = Self.timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return CredentialCheck.verdict(for: credential, httpStatus: status, body: data)
        } catch {
            return CredentialCheck.verdict(for: credential, transportError: error)
        }
    }
}
