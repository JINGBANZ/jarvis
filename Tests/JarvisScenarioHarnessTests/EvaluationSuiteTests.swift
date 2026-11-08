import Foundation
import Testing
@testable import JarvisScenarioHarness

@Suite struct EvaluationSuiteTests {
    @Test func incompleteRunNeverPassesAsSilence() throws {
        let result = EvaluationDecisionResult(
            id: "quiet", expectation: .silenceRequired,
            evidence: .init(completed: false, outcome: "brainError", replies: []), verdict: nil)
        #expect(result.status == .error)
        #expect(!EvaluationSuiteReport(suite: "coaching/intervention", results: [result]).passed)
    }
}

extension EvaluationSuiteTests {
    @Test func withdrawnReplyStillViolatesRequiredSilence() {
        let result = EvaluationDecisionResult(id: "quiet", expectation: .silenceRequired,
            evidence: .init(completed: true, outcome: "silentByModel", replies: [.init(hint: "try a map", withdrawn: true)]), verdict: nil)
        #expect(result.status == .fail)
    }
    @Test func missingHelpFailsWithoutNeedingJudge() {
        let result = EvaluationDecisionResult(id: "gap", expectation: .helpRequired,
            evidence: .init(completed: true, outcome: "silentByModel", replies: []), verdict: nil)
        #expect(result.status == .fail)
    }
    @Test func visibleHelpRequiresCompletedConfidentJudge() throws {
        let evidence = EvaluationDecisionEvidence(completed: true, outcome: "spoke", replies: [.init(hint: "low = mid + 1")])
        #expect(EvaluationDecisionResult(id: "gap", expectation: .helpRequired, evidence: evidence, verdict: nil).status == .error)
        let uncertain = try decodeVerdict(confident: false)
        #expect(EvaluationDecisionResult(id: "gap", expectation: .helpRequired, evidence: evidence, verdict: uncertain).status == .error)
    }
    @Test func groundedNonredundantHelpPassesAndRedundantHelpFails() throws {
        let evidence = EvaluationDecisionEvidence(completed: true, outcome: "spoke", replies: [.init(hint: "low = mid + 1")])
        #expect(EvaluationDecisionResult(id: "gap", expectation: .helpRequired, evidence: evidence, verdict: try decodeVerdict()).status == .pass)
        #expect(EvaluationDecisionResult(id: "gap", expectation: .helpRequired, evidence: evidence, verdict: try decodeVerdict(redundant: true)).status == .fail)
    }
    @Test func malformedAndIncompleteJudgeResponsesAreRejected() {
        #expect(throws: (any Error).self) { try InterventionVerdict.decode(.init(toolCalls: [], outputText: "looks good")) }
        #expect(throws: (any Error).self) { try InterventionVerdict.decode(.init(toolCalls: [], incompleteReason: "max_output_tokens", outputText: "{}")) }
        #expect(throws: (any Error).self) { try InterventionVerdict.decode(.init(toolCalls: [], outputText: #"{"confident":true,"grounded":true,"helpful":true,"redundant":false,"rationale":" "}"#)) }
    }
    @Test func reportsSeparateBehaviorMetricsAndSequenceSuccess() throws {
        let results: [EvaluationDecisionResult] = [
            .init(id: "episode/quiet", expectation: .silenceRequired, evidence: .init(completed: true, outcome: "spoke", replies: [.init(hint: "again")]), verdict: try decodeVerdict(redundant: true)),
            .init(id: "episode/help", expectation: .helpRequired, evidence: .init(completed: true, outcome: "spoke", replies: [.init(hint: "advance low")]), verdict: try decodeVerdict()),
        ]
        let report = EvaluationSuiteReport(suite: "coaching/intervention", results: results)
        #expect(report.unwantedInterventions == 1)
        #expect(report.helpfulFulfilled == 1)
        #expect(report.redundantInterventions == 1)
        #expect(report.sequenceSuccess == ["episode": false])
        #expect(!report.passed)
    }
    @Test func emptySuiteCannotPass() { #expect(!EvaluationSuiteReport(suite: "empty", results: []).passed) }

    @Test func calibrationFixturesCarryPositiveNegativeAndUncertainLabels() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(InterventionCalibration.self, from: Data(contentsOf: base.appendingPathComponent("JarvisLiveTests/Scenarios/judge-calibration.json")))
        #expect(fixture.examples.map(\.id) == ["helpful", "incorrect", "redundant", "insufficient-evidence", "overwhelming"])
        let good = try decodeVerdict()
        #expect(fixture.examples[0].matches(good))
        #expect(!fixture.examples[1].matches(good))
        #expect(!fixture.examples[2].matches(good))
        #expect(!fixture.examples[3].matches(good))
    }

    private func decodeVerdict(confident: Bool = true, redundant: Bool = false) throws -> InterventionVerdict {
        try InterventionVerdict.decode(.init(toolCalls: [], outputText: """
        {"confident":\(confident),"grounded":true,"helpful":true,"redundant":\(redundant),"rationale":"The inclusive lower bound must move past the midpoint to eliminate a two-element stall."}
        """))
    }
}

extension EvaluationSuiteTests {
    @Test func checkedInCatalogValidatesAndRubricIsSeparateFromModelEvents() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try CoachingReplayCatalog.load(from: base.appendingPathComponent("JarvisLiveTests/Scenarios/coaching-intervention.json"))
        #expect(catalog.episodes.count == 32)
        #expect(catalog.episodes.flatMap(\.decisions).count == 46)
        #expect(catalog.episodes.flatMap(\.decisions).flatMap(\.events).allSatisfy { !($0.text ?? "").contains("gradingGoal") })
    }
}

extension EvaluationSuiteTests {
    @Test func artifactIncludesComputedStatusesAndMetrics() throws {
        let report = EvaluationSuiteReport(suite: "fixture", results: [
            .init(id: "quiet", expectation: .silenceRequired, evidence: .init(completed: true, outcome: "silentByModel", replies: []), verdict: nil),
        ])
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let results = try #require(json["results"] as? [[String: Any]])
        #expect(results[0]["status"] as? String == "pass")
        #expect(json["passed"] as? Bool == true)
        #expect(json["unwantedInterventions"] as? Int == 0)
    }
}

extension EvaluationSuiteTests {
    @Test func manifestRejectsImpossibleExecutorPayloads() throws {
        let directory = tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("manifest.json")
        for entry in [
            #"{"id":"bad","executor":"signedApp","scenario":"B","acceptance":"signed-app-A-v1"}"#,
            #"{"id":"bad","executor":"signedApp","scenario":"A","catalog":"x.json","acceptance":"signed-app-A-v1"}"#,
            #"{"id":"bad","executor":"coachingReplay","catalog":"../x.json","acceptance":"intervention-v1"}"#,
            #"{"id":"bad","executor":"coachingReplay","acceptance":"intervention-v1"}"#,
        ] {
            try Data("{\"suites\":[\(entry)]}".utf8).write(to: url)
            #expect(throws: CoachingReplayCatalog.Failure.self) { try EvaluationSuiteCatalog.load(from: url) }
        }
    }
    @Test func pendingSpeechCannotDependOnUnreachableRequestMilestone() throws {
        let directory = tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.json")
        try Data(#"{"version":"intervention-v1","rubricVersion":"intervention-v1","episodes":[{"id":"deadlock","decisions":[{"id":"first","expectation":"silenceRequired","gradingGoal":"No help needed","triggerAt":2,"events":[{"kind":"speechPending","at":1,"speaker":"me","spokenAt":1},{"kind":"speechSettled","at":3,"speaker":"me","milestone":"attemptStarted"}],"automaticFollowups":[{"id":"next","expectation":"silenceRequired","gradingGoal":"No help needed"}]}]}]}"#.utf8).write(to: url)
        #expect(throws: CoachingReplayCatalog.Failure.self) { try CoachingReplayCatalog.load(from: url) }
    }
    @Test func runLevelAuditErrorsPreventAuthoritativePass() {
        let report = EvaluationSuiteReport(suite: "fixture", results: [
            .init(id: "quiet", expectation: .silenceRequired, evidence: .init(completed: true, outcome: "silentByModel", replies: []), verdict: nil),
        ], runErrors: ["Coach wire audit incomplete"])
        #expect(!report.passed)
    }
}
