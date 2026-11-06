#if JARVIS_LIVE_E2E
import Foundation

public struct EvaluationSuiteReport: Codable, Sendable {
    public let suite: String
    public var metadata: [String: String]
    public let results: [EvaluationDecisionResult]
    public var runErrors: [String]
    public init(suite: String, results: [EvaluationDecisionResult], metadata: [String: String] = [:], runErrors: [String] = []) {
        self.suite = suite; self.results = results; self.metadata = metadata; self.runErrors = runErrors
    }
    public var passed: Bool { runErrors.isEmpty && !results.isEmpty && results.allSatisfy { $0.status == .pass } }
    public var unwantedInterventions: Int {
        results.filter { $0.expectation == .silenceRequired && !$0.evidence.replies.isEmpty }.count
    }
    public var helpfulFulfilled: Int {
        results.filter { $0.expectation == .helpRequired && $0.status == .pass }.count
    }
    public var redundantInterventions: Int { results.filter { $0.verdict?.redundant == true }.count }
    public var sequenceSuccess: [String: Bool] {
        Dictionary(grouping: results.filter { $0.id.contains("/") }, by: { String($0.id.split(separator: "/")[0]) })
            .mapValues { $0.allSatisfy { $0.status == .pass } }
    }
    public func write(to directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("evaluation.json"), options: .atomic)
        let required = results.filter { $0.expectation == .helpRequired }.count
        let sequences = sequenceSuccess
        var text = "# \(suite)\n\nAcceptance: \(metadata["acceptance"] ?? "unspecified"); every decision must pass.\n\n"
        text += "Unwanted interventions (affected decisions): \(unwantedInterventions)\nHelpful fulfillment: \(helpfulFulfilled)/\(required)\nRedundant interventions (affected decisions): \(redundantInterventions)\nSequence success: \(sequences.values.filter { $0 }.count)/\(sequences.count)\n\n"
        for error in runErrors { text += "Run error: \(error)\n" }
        for result in results {
            text += "- \(result.id): \(result.status.rawValue), \(result.evidence.replies.count) visible replies; \(result.error ?? result.verdict?.rationale ?? result.evidence.outcome)\n"
        }
        try text.write(to: directory.appendingPathComponent("evaluation.md"), atomically: true, encoding: .utf8)
        for name in ["evaluation.json", "evaluation.md"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(name).path)
        }
    }
}


extension EvaluationSuiteReport {
    private enum CodingKeys: String, CodingKey {
        case suite, metadata, results, runErrors, passed, unwantedInterventions, helpfulFulfilled, redundantInterventions, sequenceSuccess
    }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        self.init(suite: try value.decode(String.self, forKey: .suite),
            results: try value.decode([EvaluationDecisionResult].self, forKey: .results),
            metadata: try value.decode([String: String].self, forKey: .metadata),
            runErrors: try value.decode([String].self, forKey: .runErrors))
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(suite, forKey: .suite); try value.encode(metadata, forKey: .metadata)
        try value.encode(results, forKey: .results); try value.encode(runErrors, forKey: .runErrors)
        try value.encode(passed, forKey: .passed)
        try value.encode(unwantedInterventions, forKey: .unwantedInterventions)
        try value.encode(helpfulFulfilled, forKey: .helpfulFulfilled)
        try value.encode(redundantInterventions, forKey: .redundantInterventions)
        try value.encode(sequenceSuccess, forKey: .sequenceSuccess)
    }
}

#endif
