import Foundation

extension ProviderFailure {
    /// The human sentence Activity shows for this failure: one fixed clause per category, with the
    /// structured identity and the redacted provider message quoted in parentheses, and advice
    /// where the category has a next step. Producers never author copy; they choose a category.
    /// The clause is fixed so the row stays readable; the parenthetical is what makes an
    /// unclassified failure diagnosable from a screenshot.
    public var activitySentence: String {
        activitySentenceWithoutAdvice + activityAdvice
    }

    /// The sentence without its advice clause, for a frame that appends what Jarvis is doing about
    /// the failure. Leaving the advice in front of such a frame put two different instructions on
    /// either side of its dash, one telling the reader to act and one telling them Jarvis already
    /// is; the advice reads better as the row's last word.
    public var activitySentenceWithoutAdvice: String {
        clauseAndAdvice.clause + activityDetail
    }

    /// The advice clause with its leading separator, or "" when the category has no next step.
    public var activityAdvice: String {
        clauseAndAdvice.advice.map { "; \($0)" } ?? ""
    }

    private var clauseAndAdvice: (clause: String, advice: String?) {
        let name = source.displayName
        let surface = source.surfaceNoun
        let clause: String
        var advice: String?
        switch category {
        case .authentication:
            if case .brain(let provider) = source, provider.usesLocalCLI {
                clause = "\(name) isn't signed in"
                advice = "sign in to the CLI and press Start again"
            } else {
                clause = "\(name) rejected the API key"
                advice = "check Settings → Connections"
            }
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

    /// The quoted evidence alone, with a leading space, or "" when nothing is known. Frames that
    /// place their own verb around the failure (route advance, credential verdict) use this.
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
