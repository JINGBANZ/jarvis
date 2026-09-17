import Foundation

extension ProviderFailure {
    /// The quoted identity and message make an unclassified failure diagnosable from a screenshot.
    public var activitySentence: String {
        activitySentenceWithoutAdvice + activityAdvice
    }

    /// For a frame that appends what Jarvis is doing, so the advice can come last in the row.
    public var activitySentenceWithoutAdvice: String {
        clauseAndAdvice.clause + activityDetail
    }

    /// Includes its leading separator; "" when the category has no next step.
    public var activityAdvice: String {
        clauseAndAdvice.advice.map { "; \($0)" } ?? ""
    }

    private var clauseAndAdvice: (clause: String, advice: String?) {
        if let subscription = subscriptionClauseAndAdvice { return subscription }
        let name = source.displayName
        let surface = source.surfaceNoun
        let clause: String
        var advice: String?
        switch category {
        case .authentication:
            clause = "\(name) rejected the API key"
            advice = "check Settings → Connections"
        case .quota:
            clause = "\(name) reported an exhausted quota"
            advice = "check billing"
        case .access:
            clause = "\(name) denied access"
            advice = "check your region, VPN, or API project"
        case .configuration:
            clause = "\(name) rejected the \(surface) configuration"
            advice = "check Settings → Brain"
        case .unreachable:
            clause = "\(name) couldn't be reached for \(surface)"
            advice = "check your network or VPN"
        case .disconnected:
            clause = "the \(surface) connection to \(name) was lost"
        case .rejected:
            clause = "\(name) refused the \(surface) request"
        case .unavailable:
            clause = source == .capture ? "audio capture became unavailable" : "\(name) is unavailable"
        case .timeout:
            clause = "\(name) didn't respond in time"
        case .response:
            clause = "\(name) couldn't finish the response"
        case .unknown:
            clause = "\(name) failed"
        }

        return (clause, advice)
    }

    private var subscriptionClauseAndAdvice: (clause: String, advice: String?)? {
        guard case .brain(let provider) = source, provider.servedByLocalProxy else { return nil }
        let name = source.displayName
        let signIn = (clause: "\(name) isn't signed in",
                      advice: "open Settings → Connections, press Sign in for it, then press Start")
        switch category {
        case .authentication:
            return signIn
        // The sign-in service restarts itself after a crash, so the first advice is to wait.
        case .unreachable:
            return ("\(name) couldn't reach the sign-in service",
                    "wait a moment, then press Try again in Settings → Connections")
        // Only the supervisor raises this at `.process`; an upstream 5xx reads as any outage.
        case .unavailable where stage == .process:
            return ("\(name) is unavailable", "press Try again in Settings → Connections")
        // CLIProxyAPI answers `unknown provider for model` both for a signed-out vendor and for an
        // unserved model, and a token can lapse mid-session, so the advice names both.
        case .configuration:
            return ("\(name) rejected the \(source.surfaceNoun) configuration",
                    "check Settings → Brain, or sign in again in Settings → Connections")
        case .rejected where identity.httpStatus == 429:
            return ("\(name) reached its usage limit",
                    "wait for the limit to reset, or add a fallback in Settings → Brain")
        default:
            return nil
        }
    }

    /// Includes a leading space; "" when nothing is known.
    public var activityDetail: String {
        let summary = identity.summary
        switch (summary.isEmpty, message.isEmpty) {
        case (false, false): return " (\(summary): \(message))"
        case (false, true): return " (\(summary))"
        case (true, false): return " (\(message))"
        case (true, true): return ""
        }
    }
}
