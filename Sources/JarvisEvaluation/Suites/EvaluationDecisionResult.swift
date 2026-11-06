import Foundation

public struct EvaluationDecisionResult: Codable, Sendable {
    public enum Expectation: String, Codable, Sendable { case silenceRequired, helpRequired, eitherAcceptable }
    public enum Status: String, Codable, Sendable { case pass, fail, error }
    public let id: String
    public let expectation: Expectation
    public let evidence: EvaluationDecisionEvidence
    public let verdict: InterventionVerdict?
    public var error: String?

    public init(id: String, expectation: Expectation, evidence: EvaluationDecisionEvidence,
                verdict: InterventionVerdict?, error: String? = nil) {
        self.id = id; self.expectation = expectation; self.evidence = evidence
        self.verdict = verdict; self.error = error
    }

    public var status: Status {
        guard error == nil, evidence.completed else { return .error }
        if evidence.assertionsPassed == false { return .fail }
        if evidence.replies.isEmpty {
            return expectation == .helpRequired ? .fail : .pass
        }
        if expectation == .silenceRequired { return .fail }
        guard let verdict, verdict.confident else { return .error }
        return verdict.grounded && verdict.helpful && !verdict.redundant ? .pass : .fail
    }
}

extension EvaluationDecisionResult {
    private enum CodingKeys: String, CodingKey { case id, expectation, evidence, verdict, error, status }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try value.decode(String.self, forKey: .id),
            expectation: try value.decode(Expectation.self, forKey: .expectation),
            evidence: try value.decode(EvaluationDecisionEvidence.self, forKey: .evidence),
            verdict: try value.decodeIfPresent(InterventionVerdict.self, forKey: .verdict),
            error: try value.decodeIfPresent(String.self, forKey: .error))
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(id, forKey: .id); try value.encode(expectation, forKey: .expectation)
        try value.encode(evidence, forKey: .evidence); try value.encodeIfPresent(verdict, forKey: .verdict)
        try value.encodeIfPresent(error, forKey: .error); try value.encode(status, forKey: .status)
    }
}
