import Foundation
import JarvisCore
import Testing
@testable import JarvisScenarioHarness

@Suite struct CoachingReplayTests {
    @Test func queuedSpeechRetainsActualHintAndNeverSendsRubricToCoach() async throws {
        let brain = ReplayScriptedBrain(responses: [
            .init(toolCalls: [.speak(callId: "actual", hint: "Use predecessor indices for reconstruction.")], rawToolCalls: [.init(id: "actual", name: "speak", argumentsJSON: #"{"hint":"Use predecessor indices for reconstruction.","detail":null}"#)]),
            .init(toolCalls: [.staySilent(callId: "queued")]),
            .init(toolCalls: [.staySilent(callId: "progress")]),
        ])
        let judge = ReplayScriptedBrain(responses: [.init(toolCalls: [], outputText: #"{"confident":true,"grounded":true,"helpful":true,"redundant":false,"rationale":"Tracks one chain with predecessor links."}"#)])
        let directory = try outputDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try JSONDecoder().decode(CoachingReplayCatalog.self, from: Data("""
        {"version":"intervention-v1","rubricVersion":"intervention-v1","episodes":[{"id":"episode","decisions":[
          {"id":"first","expectation":"helpRequired","gradingGoal":"SECRET_RUBRIC_reconstruction","triggerAt":2,
           "events":[{"kind":"transcript","at":0,"speaker":"them","text":"Find largest divisible subset."},
                     {"kind":"transcript","at":1,"speaker":"me","text":"I know lengths but cannot reconstruct the chain."},
                     {"kind":"transcript","at":3,"spokenAt":0.5,"speaker":"me","text":"I am still thinking about reconstruction.","milestone":"attemptStarted"}],
           "automaticFollowups":[{"id":"queued","expectation":"silenceRequired","gradingGoal":"SECRET_RUBRIC_late_fragment"}]},
          {"id":"progress","expectation":"silenceRequired","gradingGoal":"SECRET_RUBRIC_progress","triggerAt":9,
           "events":[{"kind":"transcript","at":8,"speaker":"me","text":"I will use predecessor links to reconstruct one chain."}]}
        ]}]}
        """.utf8))
        let executor = CoachingReplayExecutor(suite: "fixture/replay", target: .init(provider: .openAI, modelID: "fixture"),
            coach: brain, judge: judge, screen: NoReplayScreen())
        let report = try await executor.run(catalog, metadata: ["acceptance": "fixture"], output: directory)
        #expect(report.passed)
        #expect(report.suite == "fixture/replay")
        #expect(report.results.map(\.id) == ["episode/first", "episode/queued", "episode/progress"])
        #expect(report.results[0].evidence.attempts.count == 2)
        #expect(report.results[1].evidence.attempts[1].transcript.contains { $0.contains("spoken=0.5") })
        let messages = await brain.messages
        #expect(messages.count == 3)
        #expect(messages[1].contains { message in message.toolCalls?.contains { $0.argumentsJSON.contains("Use predecessor indices for reconstruction.") } == true })
        #expect(messages.flatMap { $0 }.allSatisfy { !($0.text ?? "").contains("SECRET_RUBRIC") })
        let judged = await judge.messages
        #expect(judged.count == 1)
        #expect(judged[0].contains { $0.text?.contains("SECRET_RUBRIC_reconstruction") == true })
        #expect(!judged[0].contains { $0.text?.contains("I am still thinking about reconstruction.") == true })
    }

    @Test @MainActor func streamedWithdrawalCountsOneVisibleReplyAcrossChunks() {
        let overlay = ReplayOverlay(clock: ReplayClock())
        overlay.showReplyProgress(.init(hint: "Use", hintComplete: false, detailMarkdown: nil))
        overlay.showReplyProgress(.init(hint: "Use a map", hintComplete: true, detailMarkdown: "One lookup"))
        overlay.showReplyProgress(nil)
        #expect(overlay.visible.count == 1)
        #expect(overlay.visible[0].withdrawn)
        #expect(overlay.visible[0].snapshots == ["Use\n", "Use a map\nOne lookup"])
        let result = EvaluationDecisionResult(id: "quiet", expectation: .silenceRequired,
            evidence: .init(completed: true, outcome: "silentByModel", replies: overlay.visible), verdict: nil)
        #expect(result.status == .fail)
    }

    @Test func providerFailureCannotPassAsSilence() async throws {
        let directory = try outputDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try JSONDecoder().decode(CoachingReplayCatalog.self, from: Data(#"{"version":"intervention-v1","rubricVersion":"intervention-v1","episodes":[{"id":"quiet","decisions":[{"id":"decision","expectation":"silenceRequired","gradingGoal":"No help needed","triggerAt":1,"events":[{"kind":"transcript","at":0,"speaker":"me","text":"The expected complexity is linear."}]}]}]}"#.utf8))
        let brain = ReplayFailingBrain()
        let executor = CoachingReplayExecutor(suite: "fixture/replay", target: .init(provider: .openAI, modelID: "fixture"),
            coach: brain, judge: brain, screen: NoReplayScreen())
        let report = try await executor.run(catalog, metadata: [:], output: directory)
        #expect(!report.passed)
        #expect(report.results[0].status == .error)
        #expect(report.results[0].evidence.attempts.count == 1)
        #expect(report.results[0].evidence.attempts[0].terminal == "exhaustion")
    }

    private func outputDirectory() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent(".jarvis/evaluation-contract-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
}

private actor ReplayScriptedBrain: BrainClient {
    var responses: [BrainResponse]
    var messages: [[ChatMessage]] = []
    init(responses: [BrainResponse]) { self.responses = responses }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        self.messages.append(messages)
        guard !responses.isEmpty else { throw InterventionVerdict.Failure.invalidJudgeReply }
        return responses.removeFirst()
    }
}

private struct ReplayFailingBrain: BrainClient {
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        throw ProviderFailure(source: .brain(.openAI), stage: .request, category: .authentication,
            disposition: .permanent, identity: .init(), message: "synthetic failure")
    }
}

private struct NoReplayScreen: ScreenCapturing {
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? { nil }
    func makeAttemptCapture() -> any ScreenCapturing { self }
    func cancelCapture() {}
}
