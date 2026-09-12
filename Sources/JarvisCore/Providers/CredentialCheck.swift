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
        /// The provider said the key itself is not valid.
        case rejected(ProviderFailure)
        /// The provider did not answer about the key: it was busy, down, out of quota, blocked by
        /// region, or never reached. The failure is quoted so the row still says which.
        case inconclusive(ProviderFailure)
    }

    public static func verdict(for credential: Credential, httpStatus: Int, body: Data?) -> Verdict {
        if (200..<300).contains(httpStatus) { return .accepted }
        let failure = classify(credential: credential, httpStatus: httpStatus, body: body)
        // This check answers one question: did the provider refuse the key. Only an authentication
        // failure answers it. An exhausted quota, a blocked region, a rate limit, and a 5xx are all
        // real problems, but none of them is the key being wrong, and calling any of them a refusal
        // sends a user to rotate a key that would work. They are not worth telling apart here: the
        // failure is quoted either way, and the live session names the cause in Activity when it
        // actually bites.
        return failure.category == .authentication ? .rejected(failure) : .inconclusive(failure)
    }

    public static func verdict(for credential: Credential, transportError: any Error) -> Verdict {
        .inconclusive(TransportFailureClassifier.classify(
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
        case .inconclusive(let failure):
            // Not "couldn't reach": a rate limit arrives over a connection that plainly worked. What
            // is true in every case here is that the key itself went unanswered.
            return "I couldn't check the key with \(name)\(failure.activityDetail)."
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
    /// transcription-only. It selects the vendor table and the name in an inconclusive sentence.
    private static func source(for credential: Credential) -> ProviderFailure.Source {
        switch credential {
        case .openAIAPIKey: .brain(.openAI)
        case .geminiAPIKey: .transcription(.gemini)
        }
    }
}
