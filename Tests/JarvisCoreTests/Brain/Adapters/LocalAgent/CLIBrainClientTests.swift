import Foundation
import Testing
@testable import JarvisCore

@Suite struct CLIBrainClientTests {
    private func makeWorkDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBrainClientTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func client(
        _ provider: BrainProvider = .claudeCode,
        workDir: URL,
        replies: [String],
        tools: [ToolDef] = coachTools,
        toolChoice: ToolChoice = .required,
        timeout: TimeInterval = BrainWorkloadTimeout.liveCoaching,
        traffic: (any BrainTrafficAuditing)? = nil,
        openDelay: TimeInterval = 0,
        failBeforeDispatch: Bool = false
    ) -> (CLIBrainClient, FakeLocalAgentRuntime) {
        let backend = FakeLocalAgentRuntime(
            replies: replies,
            openDelay: openDelay,
            failBeforeDispatch: failBeforeDispatch,
            auditLabel: provider == .claudeCode ? "warm-query" : "app-server")
        let runtime = CLIBrainRuntime(backend: backend)
        let client = CLIBrainClient(
            provider: provider,
            executable: URL(fileURLWithPath: "/fake/bin/agent"),
            model: provider == .claudeCode ? "claude-sonnet-5" : "gpt-5.6-sol",
            reasoningEffort: "low",
            workDirectory: workDir,
            timeout: timeout,
            traffic: traffic,
            trafficTag: "coach",
            systemPrompt: "coach prompt",
            tools: tools,
            toolChoice: toolChoice,
            runtime: runtime,
            prewarm: false)
        return (client, backend)
    }

    @Test func localProviderDefaultsUseTheLiveCoachingWorkload() throws {
        let workDir = try makeWorkDir()
        let (claude, _) = client(.claudeCode, workDir: workDir, replies: [])
        let (codex, _) = client(.codexCLI, workDir: workDir, replies: [])

        #expect(BrainWorkloadTimeout.liveCoaching == 15)
        #expect(claude.configuration.timeout == BrainWorkloadTimeout.liveCoaching)
        #expect(codex.configuration.timeout == BrainWorkloadTimeout.liveCoaching)

        claude.terminate()
        codex.terminate()
    }

    @Test func historyCompactionDeadlineIsProviderNeutral() throws {
        let workDir = try makeWorkDir()
        let (claudeSummarizer, _) = client(
            .claudeCode,
            workDir: workDir,
            replies: [],
            tools: [],
            toolChoice: .auto,
            timeout: BrainWorkloadTimeout.historyCompaction)
        let (codexSummarizer, _) = client(
            .codexCLI,
            workDir: workDir,
            replies: [],
            tools: [],
            toolChoice: .auto,
            timeout: BrainWorkloadTimeout.historyCompaction)

        #expect(BrainWorkloadTimeout.historyCompaction == 45)
        #expect(claudeSummarizer.configuration.timeout
                == BrainWorkloadTimeout.historyCompaction)
        #expect(codexSummarizer.configuration.timeout
                == BrainWorkloadTimeout.historyCompaction)

        claudeSummarizer.terminate()
        codexSummarizer.terminate()
    }

    /// Setup and inference are budgeted separately, so a slow runtime start cannot quietly shorten
    /// the model's deadline. Sharing one budget is what left history compaction unable to finish:
    /// a ~2s cold start came straight off a 15s ceiling the summarizer already could not meet.
    @Test func auxiliarySetupDoesNotShortenTheInferenceDeadline() async throws {
        let (client, backend) = client(
            workDir: try makeWorkDir(),
            replies: [#"{"tool":"stay_silent","arguments":{}}"#],
            timeout: 0.5,
            openDelay: 0.2)

        _ = try await client.respond(
            messages: [.system("coach prompt"), .user("hello")],
            tools: coachTools,
            toolChoice: .required)

        let turns = await backend.turns
        let finishCount = await backend.finishCount
        // The turn carries the whole configured budget, not the remainder setup left behind.
        #expect(turns.map(\.timeout) == [0.5])
        #expect(finishCount == 1)
    }

    @Test func persistentRuntimeParsesStaySilent() async throws {
        let (client, backend) = client(
            workDir: try makeWorkDir(),
            replies: [#"{"tool":"stay_silent","arguments":{}}"#])

        let response = try await client.respond(
            messages: [.system("coach prompt"), .user("hello there")],
            tools: coachTools,
            toolChoice: .required)

        #expect(response.toolCalls.count == 1)
        guard case .staySilent = response.toolCalls[0] else {
            Issue.record("expected stay_silent")
            return
        }
        let openCount = await backend.openCount
        let finishCount = await backend.finishCount
        #expect(openCount == 1)
        #expect(finishCount == 1)
    }

    @Test func oneAttemptReusesOneConversationAndSendsOnlyIncrementalFollowUp() async throws {
        let base64 = Data("jpeg".utf8).base64EncodedString()
        let (client, backend) = client(
            workDir: try makeWorkDir(),
            replies: [
                #"{"tool":"capture_screen","arguments":{}}"#,
                #"{"tool":"stay_silent","arguments":{}}"#,
            ])
        let conversation = try await client.makeConversation()
        let first = try await conversation.respond(
            messages: [.system("coach prompt"), .user("look at this")],
            tools: coachTools,
            toolChoice: .required)
        let call = try #require(first.rawToolCalls.first)
        _ = try await conversation.respond(
            messages: [
                .system("coach prompt"),
                .user("look at this"),
                .assistantToolCalls([call]),
                .init(role: .tool, text: "screenshot captured", toolCallId: call.id),
                .userImage(base64),
            ],
            tools: coachTools,
            toolChoice: .required)
        await conversation.finish()

        let turns = await backend.turns
        #expect(turns.count == 2)
        let openCount = await backend.openCount
        let finishCount = await backend.finishCount
        #expect(openCount == 1)
        #expect(finishCount == 1)
        #expect(turns[0].text.contains("## Conversation"))
        #expect(turns[0].text.contains("look at this"))
        #expect(turns[1].text.contains("## New input"))
        #expect(turns[1].text.contains("screenshot captured"))
        #expect(!turns[1].text.contains("look at this"))
        #expect(!turns[1].text.contains(#""tool":"capture_screen""#))
        #expect(turns[1].imageCount == 1)
    }

    @Test func rewrittenConversationInsideAttemptFailsInsteadOfColdReplay() async throws {
        let (client, backend) = client(
            workDir: try makeWorkDir(),
            replies: [#"{"tool":"capture_screen","arguments":{}}"#])
        let conversation = try await client.makeConversation()
        _ = try await conversation.respond(
            messages: [.system("coach prompt"), .user("first")],
            tools: coachTools,
            toolChoice: .required)

        do {
            _ = try await conversation.respond(
                messages: [.system("coach prompt"), .user("rewritten")],
                tools: coachTools,
                toolChoice: .required)
            Issue.record("expected rewritten conversation to fail")
        } catch {
            #expect(error.localizedDescription.contains("rewritten"))
        }
        await conversation.finish()
        let openCount = await backend.openCount
        #expect(openCount == 1)
    }

    @Test func screenshotStaysInlineAndTrafficRecordRedactsItsBytes() async throws {
        let workDir = try makeWorkDir()
        let traffic = await FileSessionAudit.readyForTesting(directory: workDir)
        let base64 = Data("fake-jpeg-payload".utf8).base64EncodedString()
        let (client, backend) = client(
            workDir: workDir,
            replies: [#"{"tool":"stay_silent","arguments":{}}"#],
            traffic: traffic)

        _ = try await client.respond(
            messages: [.system("coach prompt"), .user("look"), .userImage(base64)],
            tools: coachTools,
            toolChoice: .required)
        _ = await traffic.closeForTesting()

        let turns = await backend.turns
        #expect(turns.first?.imageCount == 1)
        let jsonl = try String(
            contentsOf: workDir.appendingPathComponent(FileSessionAudit.brainTrafficFilename),
            encoding: .utf8)
        #expect(!jsonl.contains(base64))
        #expect(jsonl.contains("redacted"))
        #expect(jsonl.contains(#""runtime":"warm-query""#))
    }

    @Test func successfulTrafficCarriesPersistentRuntimePhasesWithoutSpawnPhase() async throws {
        let workDir = try makeWorkDir()
        let traffic = await FileSessionAudit.readyForTesting(directory: workDir)
        let (client, _) = client(
            workDir: workDir,
            replies: [#"{"tool":"stay_silent","arguments":{}}"#],
            traffic: traffic)

        _ = try await client.respond(
            messages: [.system("coach prompt"), .user("hi")],
            tools: coachTools,
            toolChoice: .required)
        _ = await traffic.closeForTesting()

        let jsonl = try String(
            contentsOf: workDir.appendingPathComponent(FileSessionAudit.brainTrafficFilename),
            encoding: .utf8)
        let line = try #require(jsonl.split(separator: "\n").first)
        let entry = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let phases = try #require(entry["phases"] as? [String: Any])
        #expect(phases["queuedMs"] is Int)
        #expect(phases["firstOutputMs"] is Int)
        #expect(phases["outputMs"] is Int)
        #expect(phases["parseMs"] is Int)
        #expect(phases["totalMs"] is Int)
        #expect(phases["spawnMs"] == nil)
        #expect(phases["stdinMs"] == nil)
        #expect(entry["ms"] as? Int == phases["totalMs"] as? Int)
    }

    @Test func runtimeFailureIsTemporaryAndNeverOpensAColdFallback() async throws {
        let workDir = try makeWorkDir()
        let traffic = await FileSessionAudit.readyForTesting(directory: workDir)
        let backend = FakeLocalAgentRuntime(
            replies: [],
            openError: NSError(
                domain: "test",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "app-server unavailable"]),
            auditLabel: "app-server")
        let runtime = CLIBrainRuntime(backend: backend)
        let client = CLIBrainClient(
            provider: .codexCLI,
            executable: URL(fileURLWithPath: "/fake/bin/codex"),
            model: "",
            workDirectory: workDir,
            traffic: traffic,
            systemPrompt: "coach prompt",
            tools: coachTools,
            toolChoice: .required,
            runtime: runtime,
            prewarm: false)

        do {
            _ = try await client.respond(
                messages: [.system("coach prompt"), .user("hi")],
                tools: coachTools,
                toolChoice: .required)
            Issue.record("expected runtime failure")
        } catch {
            #expect(BrainFailure(error).disposition == .temporary)
            #expect(error.localizedDescription.contains("app-server unavailable"))
        }
        _ = await traffic.closeForTesting()
        let openCount = await backend.openCount
        let turns = await backend.turns
        #expect(openCount == 1)
        #expect(turns.isEmpty)
        let jsonl = try String(
            contentsOf: workDir.appendingPathComponent(FileSessionAudit.brainTrafficFilename),
            encoding: .utf8)
        let lines = jsonl.split(separator: "\n")
        #expect(lines.count == 1)
        #expect(jsonl.contains(#""runtime":"app-server""#))
        #expect(jsonl.contains(#""record_kind":"pre_request_failure""#))
        #expect(jsonl.contains("app-server unavailable"))
    }

    @Test func preparedTurnFailureBeforeDispatchIsNotAProviderCall() async throws {
        let workDir = try makeWorkDir()
        let traffic = await FileSessionAudit.readyForTesting(directory: workDir)
        let (client, backend) = client(
            .codexCLI,
            workDir: workDir,
            replies: [#"{"tool":"stay_silent","arguments":{}}"#],
            traffic: traffic,
            failBeforeDispatch: true)

        do {
            _ = try await client.respond(
                messages: [.system("coach prompt"), .user("prepared but unsent")],
                tools: coachTools,
                toolChoice: .required)
            Issue.record("expected the transport to reject the prepared turn")
        } catch {
            #expect(error.localizedDescription.contains("before dispatch"))
        }
        _ = await traffic.closeForTesting()

        let turns = await backend.turns
        #expect(turns.count == 1)
        let jsonl = try String(
            contentsOf: workDir.appendingPathComponent(FileSessionAudit.brainTrafficFilename),
            encoding: .utf8)
        #expect(jsonl.contains("prepared but unsent"))
        #expect(jsonl.contains(#""record_kind":"pre_request_failure""#))
        #expect(!jsonl.contains(#""record_kind":"provider_call""#))
    }

    @Test func failureAfterDispatchRemainsAProviderCall() async throws {
        let workDir = try makeWorkDir()
        let traffic = await FileSessionAudit.readyForTesting(directory: workDir)
        let (client, _) = client(
            .codexCLI,
            workDir: workDir,
            replies: [],
            traffic: traffic)

        do {
            _ = try await client.respond(
                messages: [.system("coach prompt"), .user("sent without a reply")],
                tools: coachTools,
                toolChoice: .required)
            Issue.record("expected the dispatched turn to fail")
        } catch {
            #expect(error.localizedDescription.contains("no fake reply"))
        }
        _ = await traffic.closeForTesting()

        let jsonl = try String(
            contentsOf: workDir.appendingPathComponent(FileSessionAudit.brainTrafficFilename),
            encoding: .utf8)
        #expect(jsonl.contains(#""record_kind":"provider_call""#))
        #expect(!jsonl.contains(#""record_kind":"pre_request_failure""#))
    }

    @Test func sharedRuntimeStaysAliveUntilEveryReachableClientReleasesIt() async throws {
        let workDir = try makeWorkDir()
        let backend = FakeLocalAgentRuntime(
            replies: [#"{"tool":"stay_silent","arguments":{}}"#])
        let runtime = CLIBrainRuntime(backend: backend)
        let firstTargetCoach = makeClient(
            provider: .codexCLI,
            workDir: workDir,
            runtime: runtime,
            systemPrompt: "first coach",
            tools: coachTools)
        let firstTargetSummarizer = makeClient(
            provider: .codexCLI,
            workDir: workDir,
            runtime: runtime,
            systemPrompt: "first summarizer",
            tools: [])
        let fallbackCoach = makeClient(
            provider: .codexCLI,
            workDir: workDir,
            runtime: runtime,
            systemPrompt: "fallback coach",
            tools: coachTools)
        let fallbackSummarizer = makeClient(
            provider: .codexCLI,
            workDir: workDir,
            runtime: runtime,
            systemPrompt: "fallback summarizer",
            tools: [])

        firstTargetCoach.terminate()
        firstTargetSummarizer.terminate()
        #expect(backend.terminationCount == 0)

        _ = try await fallbackCoach.respond(
            messages: [.system("fallback coach"), .user("continue forward")],
            tools: coachTools,
            toolChoice: .required)
        #expect(await backend.openCount == 1)

        fallbackCoach.terminate()
        #expect(backend.terminationCount == 0)
        fallbackSummarizer.terminate()
        #expect(backend.terminationCount == 1)

        firstTargetCoach.terminate()
        fallbackSummarizer.terminate()
        #expect(backend.terminationCount == 1)
    }

    @Test func toolLessCallReturnsPlainText() async throws {
        let (client, _) = client(
            workDir: try makeWorkDir(),
            replies: ["a tidy briefing"],
            tools: [],
            toolChoice: .auto)
        let response = try await client.respond(
            messages: [.system("coach prompt"), .user("summarize")],
            tools: [],
            toolChoice: .auto)
        #expect(response.outputText == "a tidy briefing")
        #expect(response.toolCalls.isEmpty)
    }

    @Test func forcedToolKeepsInitializedInstructionsStableAndUsesTurnDirective() async throws {
        let (client, backend) = client(
            workDir: try makeWorkDir(),
            replies: [#"{"tool":"speak","arguments":{"lines":["tip"]}}"#])
        _ = try await client.respond(
            messages: [.system("coach prompt"), .user("help")],
            tools: coachTools,
            toolChoice: .force(speakTool.name))

        let turns = await backend.turns
        let turn = try #require(turns.first)
        #expect(turn.text.contains("You MUST call the `speak` tool this turn."))
        let configurations = await backend.configurations
        #expect(configurations.first?.instructions.contains("You MUST call the `speak`") == false)
    }

    @Test func forcedSpeakRejectsAnotherToolAndSpeaksProse() async throws {
        let (client, _) = client(
            workDir: try makeWorkDir(),
            replies: ["""
                Try a hash map here.
                {"tool":"stay_silent","arguments":{}}
                """])
        let response = try await client.respond(
            messages: [.system("coach prompt"), .user("help")],
            tools: coachTools,
            toolChoice: .force(speakTool.name))
        guard case .speak(_, let lines) = response.toolCalls.first else {
            Issue.record("expected forced speak")
            return
        }
        #expect(lines == ["Try a hash map here."])
        #expect(response.rawToolCalls.first?.argumentsJSON.contains("Try a hash map here.") == true)
    }

    @Test func malformedSpeakArgumentsAreNotAnEmptySpokenTurn() async throws {
        let (client, _) = client(
            workDir: try makeWorkDir(),
            replies: [#"{"tool":"speak","arguments":{}}"#])
        let response = try await client.respond(
            messages: [.system("coach prompt"), .user("hm")],
            tools: coachTools,
            toolChoice: .required)
        #expect(response.toolCalls.isEmpty)
    }

    @Test func speakArgumentsParseNestedAndFlattenedShapes() throws {
        let (client, _) = client(workDir: try makeWorkDir(), replies: [])
        for reply in [
            #"{"tool":"speak","arguments":{"lines":["one","two"]}}"#,
            #"{"tool":"speak","lines":["one","two"]}"#,
        ] {
            let response = client.parse(
                reply: reply, tools: coachTools, toolChoice: .required)
            guard case .speak(_, let lines) = response.toolCalls.first else {
                Issue.record("expected speak for \(reply)")
                continue
            }
            #expect(lines == ["one", "two"])
        }
    }

    @Test func toolJSONSurvivesProseCodeFencesAndEarlierBraces() throws {
        let (client, _) = client(workDir: try makeWorkDir(), replies: [])
        let response = client.parse(
            reply: """
                A set like {a, b} is useful.
                ```json
                {"tool":"stay_silent","arguments":{}}
                ```
                """,
            tools: coachTools,
            toolChoice: .required)
        guard case .staySilent = response.toolCalls.first else {
            Issue.record("expected stay_silent")
            return
        }
    }

    @Test func effortMappingsRemainProviderSpecific() {
        #expect(CLIBrainClient.claudeEffort("none") == "low")
        #expect(CLIBrainClient.claudeEffort("high") == "high")
        #expect(CLIBrainClient.codexEffort("none") == "low")
        #expect(CLIBrainClient.codexEffort("xhigh") == "xhigh")
    }

    private func makeClient(
        provider: BrainProvider,
        workDir: URL,
        runtime: CLIBrainRuntime,
        systemPrompt: String,
        tools: [ToolDef]
    ) -> CLIBrainClient {
        CLIBrainClient(
            provider: provider,
            executable: URL(fileURLWithPath: "/fake/bin/agent"),
            model: provider == .claudeCode ? "claude-sonnet-5" : "gpt-5.6-sol",
            workDirectory: workDir,
            systemPrompt: systemPrompt,
            tools: tools,
            toolChoice: tools.isEmpty ? .auto : .required,
            runtime: runtime,
            prewarm: false)
    }
}

private actor FakeLocalAgentRuntime: LocalAgentRuntimeBackend {
    // Stand in for the transport being faked, so audit-fidelity assertions stay meaningful.
    nonisolated let auditLabel: String
    struct RecordedTurn: Sendable {
        let text: String
        let imageCount: Int
        let timeout: TimeInterval
    }

    private var replies: [String]
    private let openError: (any Error)?
    private let openDelay: TimeInterval
    private let failBeforeDispatch: Bool
    private(set) var configurations: [LocalAgentConversationConfiguration] = []
    private(set) var turns: [RecordedTurn] = []
    private(set) var openCount = 0
    private(set) var finishCount = 0
    nonisolated let termination = RuntimeTerminationRecorder()
    nonisolated var terminationCount: Int { termination.count }

    init(
        replies: [String],
        openError: (any Error)? = nil,
        openDelay: TimeInterval = 0,
        failBeforeDispatch: Bool = false,
        auditLabel: String = "warm-query"
    ) {
        self.auditLabel = auditLabel
        self.replies = replies
        self.openError = openError
        self.openDelay = openDelay
        self.failBeforeDispatch = failBeforeDispatch
    }

    func prepare(for configuration: LocalAgentConversationConfiguration) async throws {
        configurations.append(configuration)
    }

    func openConversation(
        for configuration: LocalAgentConversationConfiguration,
        deadline: Date
    )
        async throws -> any LocalAgentConversation {
        configurations.append(configuration)
        openCount += 1
        if openDelay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(openDelay * 1_000_000_000))
        }
        if terminationCount > 0 {
            throw NSError(
                domain: "FakeLocalAgentRuntime",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "runtime terminated"])
        }
        if let openError { throw openError }
        return FakeLocalAgentConversation(runtime: self)
    }

    nonisolated func terminateNow() {
        termination.record()
    }

    fileprivate func answer(
        _ turn: LocalAgentTurn,
        onRequestDispatched: @Sendable () -> Void
    ) throws -> LocalAgentTurnResult {
        let text = turn.input.compactMap { item -> String? in
            guard case .text(let text) = item else { return nil }
            return text
        }.joined(separator: "\n")
        let imageCount = turn.input.count(where: {
            if case .imageJPEG = $0 { return true }
            return false
        })
        turns.append(RecordedTurn(
            text: text,
            imageCount: imageCount,
            timeout: turn.timeout))
        if failBeforeDispatch {
            throw NSError(
                domain: "FakeLocalAgentRuntime",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "turn rejected before dispatch"])
        }
        let dispatched = DispatchTime.now().uptimeNanoseconds
        onRequestDispatched()
        guard !replies.isEmpty else {
            throw NSError(
                domain: "FakeLocalAgentRuntime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no fake reply"])
        }
        let reply = replies.removeFirst()
        return LocalAgentTurnResult(
            reply: reply,
            metadata: nil,
            dispatchedAt: dispatched,
            firstAssistantAt: dispatched,
            completedAt: dispatched)
    }

    fileprivate func didFinish() {
        finishCount += 1
    }
}

/// Test-only synchronous state used by the actor's nonisolated termination callback.
private final class RuntimeTerminationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock { value += 1 }
    }
}

private final class FakeLocalAgentConversation: LocalAgentConversation, @unchecked Sendable {
    let runtime: FakeLocalAgentRuntime

    init(runtime: FakeLocalAgentRuntime) {
        self.runtime = runtime
    }

    func respond(
        to turn: LocalAgentTurn,
        onRequestDispatched: @Sendable () -> Void
    ) async throws -> LocalAgentTurnResult {
        try await runtime.answer(
            turn,
            onRequestDispatched: onRequestDispatched)
    }

    func finish() async {
        await runtime.didFinish()
    }
}
