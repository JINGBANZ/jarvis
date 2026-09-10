import Foundation

/// Turns the one request Settings makes after a key is saved into a verdict a person can read.
///
/// The verdict comes from the same vendor table a live session uses, so Settings and a failed
/// session never disagree about what a key did. A models-list call proves the key, the network path,
/// and the region; it does not prove billing, which OpenAI only reports on a real request, so
/// `accepted` is worded as acceptance rather than health.
public enum CredentialCheck {
    public enum Verdict: Sendable, Equatable {
        case accepted
        /// The provider answered about the key itself, and the answer was no.
        case rejected(ProviderFailure)
        /// Nothing was learned about the key: the request never arrived, or the provider was down.
        case unreachable(ProviderFailure)
    }

    public static func verdict(for credential: Credential, httpStatus: Int, body: Data?) -> Verdict {
        if (200..<300).contains(httpStatus) { return .accepted }
        let failure = classify(credential: credential, httpStatus: httpStatus, body: body)
        // A 5xx says the provider is having trouble, not that the key is bad. Calling it a rejection
        // would send a user to rotate a key that is fine.
        return (500..<600).contains(httpStatus) ? .unreachable(failure) : .rejected(failure)
    }

    public static func verdict(for credential: Credential, transportError: any Error) -> Verdict {
        .unreachable(TransportFailureClassifier.classify(
            error: transportError, source: source(for: credential), everReady: false))
    }

    /// The sentence Settings shows under the key row. The parenthetical is the failure's own quoted
    /// evidence, already redacted, so a message echoing the key back cannot render it.
    public static func statusText(_ verdict: Verdict, for credential: Credential) -> String {
        let name = credential.vendorName
        switch verdict {
        case .accepted:
            return "\(name) accepted the key."
        case .rejected(let failure):
            return "\(name) refused the key\(failure.activityDetail)."
        case .unreachable(let failure):
            return "I couldn't reach \(name)\(failure.activityDetail)."
        }
    }

    private static func classify(
        credential: Credential, httpStatus: Int, body: Data?
    ) -> ProviderFailure {
        switch credential {
        case .openAIAPIKey:
            OpenAIFailureClassifier.classify(
                httpStatus: httpStatus, body: body, source: .brain(.openAI), stage: .request)
        case .geminiAPIKey:
            GeminiFailureClassifier.classify(
                httpStatus: httpStatus, body: body, source: .transcription(.gemini), stage: .request)
        }
    }

    /// The surface each key is mainly for: OpenAI's key can reach the brain, Gemini's is
    /// transcription-only. It selects the vendor table and the noun in an unreachable sentence.
    private static func source(for credential: Credential) -> ProviderFailure.Source {
        switch credential {
        case .openAIAPIKey: .brain(.openAI)
        case .geminiAPIKey: .transcription(.gemini)
        }
    }
}
