import Foundation

/// A models-list call doesn't prove billing, which OpenAI reports only on a real request, so
/// `accepted` means acceptance, not health.
public enum CredentialCheck {
    public enum Verdict: Sendable, Equatable {
        case accepted
        case rejected(ProviderFailure)
        /// The provider didn't answer about the key: busy, down, out of quota, region-blocked, or
        /// unreachable.
        case inconclusive(ProviderFailure)
    }

    public static func verdict(for credential: Credential, httpStatus: Int, body: Data?) -> Verdict {
        if (200..<300).contains(httpStatus) { return .accepted }
        let failure = classify(credential: credential, httpStatus: httpStatus, body: body)
        // Only an authentication failure refuses the key. Calling quota or region a refusal would
        // send a user to rotate a key that works.
        return failure.category == .authentication ? .rejected(failure) : .inconclusive(failure)
    }

    public static func verdict(for credential: Credential, transportError: any Error) -> Verdict {
        .inconclusive(TransportFailureClassifier.classify(
            error: transportError, source: source(for: credential), everReady: false))
    }

    /// The quoted detail is already redacted, so a message echoing the key back cannot render it.
    public static func statusText(_ verdict: Verdict, for credential: Credential) -> String {
        let name = credential.vendorName
        switch verdict {
        case .accepted:
            return "\(name) accepted the key."
        case .rejected(let failure):
            return "\(name) refused the key\(failure.activityDetail)."
        case .inconclusive(let failure):
            // Not "couldn't reach": a rate limit arrives over a connection that worked.
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

    private static func source(for credential: Credential) -> ProviderFailure.Source {
        switch credential {
        case .openAIAPIKey: .brain(.openAI)
        case .geminiAPIKey: .transcription(.gemini)
        }
    }
}
