import Testing
import Foundation
@testable import JarvisCore

@Suite struct CLIBrainClientTests {
    /// NSLock-guarded cell so the `@Sendable` fake runner can hand the invocation (and observations
    /// made while the "process" runs) back to the test. `@unchecked Sendable`: lock-guarded.
    private final class Captured<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        var value: T? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private func makeWorkDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBrainClientTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func claudeEnvelope(_ result: String, isError: Bool = false) -> String {
        let obj: [String: Any] = ["type": "result", "is_error": isError, "result": result]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func client(_ provider: BrainProvider, workDir: URL,
                        model: String = "claude-sonnet-5",
                        effort: String = "low",
                        codexSupportedFeatures: Set<String>? = nil,
                        run: @escaping CLIBrainClient.Runner) -> CLIBrainClient {
        CLIBrainClient(provider: provider, executable: URL(fileURLWithPath: "/fake/bin/cli"),
                       model: model, reasoningEffort: effort, workDirectory: workDir,
                       codexSupportedFeatures: codexSupportedFeatures
                           ?? (provider == .codexCLI
                               ? Set(CLIBrainClient.codexDisabledAgentFeatures) : []),
                       run: run)
    }

    // MARK: - Claude invocation + parsing

    @Test func claudeRunCarriesPromptAndProtocolAndParsesStaySilent() async throws {
        let workDir = try makeWorkDir()
        let captured = Captured<AgentCLIRun>()
        let envelope = claudeEnvelope(#"{"tool":"stay_silent","arguments":{}}"#)
        let c = client(.claudeCode, workDir: workDir) { run, _ in
            captured.value = run
            return AgentCLIOutput(stdout: envelope, stderr: "", exitCode: 0)
        }
        let response = try await c.respond(messages: [.system("coach prompt"), .user("hello there")],
                                           tools: coachTools, toolChoice: .required)

        let run = try #require(captured.value)
        #expect(run.arguments.contains("-p"))
        #expect(run.arguments.contains("stream-json"))              // inline-image capable input
        #expect(run.arguments.contains("claude-sonnet-5"))
        #expect(run.arguments.contains("--setting-sources"))        // no CLAUDE.md/plugins bleed-in
        #expect(run.arguments.contains("--no-session-persistence")) // no transcript copy in ~/.claude
        #expect(run.arguments.contains("--strict-mcp-config"))      // zero MCP servers in a Jarvis turn
        // Instructions replace Claude Code's own persona via --system-prompt: system text + the
        // tool protocol travel there, the conversation goes to stdin.
        let sysIdx = try #require(run.arguments.firstIndex(of: "--system-prompt"))
        let instructions = run.arguments[sysIdx + 1]
        #expect(instructions.contains("coach prompt"))
        #expect(instructions.contains("stay_silent"))               // tool protocol lists the tools
        #expect(instructions.contains("You MUST pick exactly one tool"))  // .required phrasing
        let effortIdx = try #require(run.arguments.firstIndex(of: "--effort"))
        #expect(run.arguments[effortIdx + 1] == "low")
        // Every built-in tool is disabled — a claude turn is structurally one model call.
        let toolsIdx = try #require(run.arguments.firstIndex(of: "--tools"))
        #expect(run.arguments[toolsIdx + 1] == "")
        let prompt = try #require(run.stdin)
        #expect(prompt.contains("hello there"))
        #expect(!prompt.contains("coach prompt"))                   // not duplicated into stdin

        #expect(response.toolCalls.count == 1)
        guard case .staySilent = response.toolCalls[0] else {
            Issue.record("expected staySilent, got \(response.toolCalls)"); return
        }
        #expect(response.rawToolCalls.first?.name == "stay_silent")
    }

    @Test func speakArgumentsParseNestedAndFlattenedShapes() async throws {
        for reply in [#"{"tool":"speak","arguments":{"lines":["tip one","tip two"]}}"#,
                      #"{"tool":"speak","lines":["tip one","tip two"]}"#] {
            let workDir = try makeWorkDir()
            let c = client(.claudeCode, workDir: workDir) { _, _ in
                AgentCLIOutput(stdout: self.claudeEnvelope(reply), stderr: "", exitCode: 0)
            }
            let response = try await c.respond(messages: [.user("hi")], tools: coachTools,
                                               toolChoice: .required)
            guard case .speak(_, let lines) = response.toolCalls.first else {
                Issue.record("expected speak for \(reply)"); return
            }
            #expect(lines == ["tip one", "tip two"])
        }
    }

    @Test func toolJSONSurvivesProseAndCodeFences() {
        let reply = """
        Let me look at the screen first.
        ```json
        {"tool":"capture_screen","arguments":{}}
        ```
        """
        let call = CLIBrainClient.extractToolCall(from: reply)
        #expect(call?.name == "capture_screen")
    }

    @Test func lastToolObjectWinsWhenProseContainsBraces() {
        let reply = #"The schema {"a":1} is irrelevant. {"tool":"stay_silent","arguments":{}}"#
        #expect(CLIBrainClient.extractToolCall(from: reply)?.name == "stay_silent")
    }

    // MARK: - Screenshots

    @Test func claudeScreenshotRidesInlineAsAnImageBlock() async throws {
        // Inline base64 via stream-json input: the image reaches the model in the SAME call — no
        // Read round trip, and nothing ever written to disk for it.
        let workDir = try makeWorkDir()
        let base64 = Data("fake-jpeg".utf8).base64EncodedString()
        let observed = Captured<(files: [String], run: AgentCLIRun)>()
        let c = client(.claudeCode, workDir: workDir) { run, _ in
            observed.value = (files: try FileManager.default.contentsOfDirectory(atPath: workDir.path),
                              run: run)
            return AgentCLIOutput(stdout: self.claudeEnvelope(#"{"tool":"stay_silent","arguments":{}}"#),
                                  stderr: "", exitCode: 0)
        }
        _ = try await c.respond(messages: [.user("look"), .userImage(base64)],
                                tools: coachTools, toolChoice: .required)
        let seen = try #require(observed.value)
        #expect(seen.files.isEmpty)   // no on-disk copy, even while the CLI runs
        let message = try #require(try JSONSerialization.jsonObject(
            with: Data((seen.run.stdin ?? "").utf8)) as? [String: Any])
        let content = try #require((message["message"] as? [String: Any])?["content"] as? [[String: Any]])
        let imageBlock = try #require(content.first { $0["type"] as? String == "image" })
        #expect((imageBlock["source"] as? [String: Any])?["data"] as? String == base64)
        #expect(content.contains { block in
            (block["text"] as? String)?.contains("look") == true    // the spoken text rides beside it
        })
    }

    @Test func codexScreenshotRidesAsImageFlag() async throws {
        let workDir = try makeWorkDir()
        let base64 = Data("fake-jpeg".utf8).base64EncodedString()
        let captured = Captured<AgentCLIRun>()
        let c = client(.codexCLI, workDir: workDir, model: "gpt-5.6-sol") { run, _ in
            captured.value = run
            // Codex's reply lands in the --output-last-message file, not stdout.
            if let i = run.arguments.firstIndex(of: "--output-last-message") {
                try #"{"tool":"stay_silent","arguments":{}}"#
                    .write(toFile: run.arguments[i + 1], atomically: true, encoding: .utf8)
            }
            return AgentCLIOutput(stdout: "codex log noise", stderr: "", exitCode: 0)
        }
        let response = try await c.respond(messages: [.userImage(base64)],
                                           tools: coachTools, toolChoice: .required)
        let run = try #require(captured.value)
        #expect(run.arguments.contains("exec"))
        #expect(run.arguments.contains("--ephemeral"))            // no rollout transcript in ~/.codex
        #expect(run.arguments.contains("--ignore-user-config"))   // no personal config injected
        #expect(run.arguments.contains("--ignore-rules"))         // no exec-policy discovery
        #expect(run.arguments.contains("project_root_markers=[]"))
        #expect(run.arguments.contains("project_doc_max_bytes=0"))
        let disabled = Set(zip(run.arguments, run.arguments.dropFirst()).compactMap {
            flag, value in flag == "--disable" ? value : nil
        })
        #expect(disabled == Set(CLIBrainClient.codexDisabledAgentFeatures))
        #expect(run.stdin?.hasPrefix(CLIBrainClient.codexDirectResponseInstruction) == true)
        #expect(run.stdin?.contains("not callable Codex tools") == true)
        #expect(run.timeout == CLIBrainClient.codexDefaultTimeout)
        #expect(run.arguments.contains("-i"))
        let modelIndex = try #require(run.arguments.firstIndex(of: "-m"))
        #expect(run.arguments[modelIndex + 1] == "gpt-5.6-sol")
        guard case .staySilent = response.toolCalls.first else {
            Issue.record("expected staySilent"); return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: workDir.path).isEmpty)
    }

    @Test func everyCodexModelReusesTheSharedEffortAndDisablesMCP() async throws {
        let efforts = [
            (ReasoningEffort.none, ReasoningEffort.low),
            (.low, .low),
            (.medium, .medium),
            (.high, .high),
        ]
        for model in BrainModelCatalog.models(for: .codexCLI) {
            for (effort, expected) in efforts {
                let workDir = try makeWorkDir()
                let captured = Captured<AgentCLIRun>()
                let c = client(
                    .codexCLI, workDir: workDir, model: model.id, effort: effort.rawValue
                ) { run, _ in
                    captured.value = run
                    return AgentCLIOutput(stdout: "", stderr: "", exitCode: 0)
                }
                _ = try? await c.respond(messages: [.user("x")], tools: [], toolChoice: .auto)
                let arguments = try #require(captured.value).arguments
                #expect(arguments.contains("model_reasoning_effort=\(expected.rawValue)"))
                #expect(arguments.contains("mcp_servers={}"))
                let modelIndex = try #require(arguments.firstIndex(of: "-m"))
                #expect(arguments[modelIndex + 1] == model.id)
            }
        }
    }

    @Test func codexDisablesOnlyFeaturesAdvertisedByTheInstalledCLI() async throws {
        let workDir = try makeWorkDir()
        let captured = Captured<AgentCLIRun>()
        let c = client(.codexCLI, workDir: workDir, model: "gpt-5.6-sol",
                       codexSupportedFeatures: ["shell_tool", "renamed_future_feature"]) { run, _ in
            captured.value = run
            return AgentCLIOutput(stdout: "", stderr: "", exitCode: 0)
        }

        _ = try? await c.respond(messages: [.user("x")], tools: [], toolChoice: .auto)
        let arguments = try #require(captured.value).arguments
        let disabled = zip(arguments, arguments.dropFirst()).compactMap {
            flag, value in flag == "--disable" ? value : nil
        }
        #expect(disabled == ["shell_tool"])
        #expect(!arguments.contains("code_mode_host"))
        #expect(!arguments.contains("renamed_future_feature"))
    }

    @Test func everyClaudeModelReusesTheSharedEffort() async throws {
        let efforts = [
            (ReasoningEffort.none, ReasoningEffort.low),
            (.low, .low),
            (.medium, .medium),
            (.high, .high),
        ]
        for model in BrainModelCatalog.models(for: .claudeCode) {
            for (effort, expected) in efforts {
                let workDir = try makeWorkDir()
                let captured = Captured<AgentCLIRun>()
                let c = client(
                    .claudeCode, workDir: workDir, model: model.id, effort: effort.rawValue
                ) { run, _ in
                    captured.value = run
                    return AgentCLIOutput(
                        stdout: self.claudeEnvelope("ok"), stderr: "", exitCode: 0)
                }
                _ = try await c.respond(messages: [.user("x")], tools: [], toolChoice: .auto)
                let arguments = try #require(captured.value).arguments
                let effortIndex = try #require(arguments.firstIndex(of: "--effort"))
                #expect(arguments[effortIndex + 1] == expected.rawValue)
                let modelIndex = try #require(arguments.firstIndex(of: "--model"))
                #expect(arguments[modelIndex + 1] == model.id)
            }
        }
    }

    // MARK: - Tool-less calls and fallbacks

    @Test func toolLessCallReturnsPlainText() async throws {
        // The summarizer/evaluator path: no tools, the reply text IS the payload.
        let workDir = try makeWorkDir()
        let c = client(.claudeCode, workDir: workDir) { _, _ in
            AgentCLIOutput(stdout: self.claudeEnvelope("a tidy briefing"), stderr: "", exitCode: 0)
        }
        let response = try await c.respond(messages: [.system("summarize"), .user("stuff")],
                                           tools: [], toolChoice: .auto)
        #expect(response.outputText == "a tidy briefing")
        #expect(response.toolCalls.isEmpty)
    }

    /// A one-turn forced hint must not rewrite the system prompt: instructions stay byte-identical
    /// to a `.required` turn (they're the provider's cacheable prefix — a session audit showed the
    /// old in-instructions directive paying two full cache misses per hint), and the directive rides
    /// in the conversation's trailer instead.
    @Test func forcedToolKeepsInstructionsStableAndDirectsViaTheTurn() async throws {
        let instructionsAndStdin = { (choice: ToolChoice) async throws -> (String, String) in
            let captured = Captured<AgentCLIRun>()
            let c = self.client(.claudeCode, workDir: try self.makeWorkDir()) { run, _ in
                captured.value = run
                return AgentCLIOutput(stdout: self.claudeEnvelope(#"{"tool":"speak","arguments":{"lines":["t"]}}"#),
                                      stderr: "", exitCode: 0)
            }
            _ = try await c.respond(messages: [.system("coach prompt"), .user("help")],
                                    tools: coachTools, toolChoice: choice)
            let run = try #require(captured.value)
            let sysIdx = try #require(run.arguments.firstIndex(of: "--system-prompt"))
            return (run.arguments[sysIdx + 1], try #require(run.stdin))
        }
        let (requiredInstructions, requiredStdin) = try await instructionsAndStdin(.required)
        let (forcedInstructions, forcedStdin) = try await instructionsAndStdin(.force(speakTool.name))
        #expect(forcedInstructions == requiredInstructions)
        #expect(forcedStdin.contains("You MUST call the `speak` tool this turn."))
        #expect(!requiredStdin.contains("You MUST call the `speak` tool"))
    }

    @Test func forcedSpeakRejectsAnotherToolAndSpeaksTheProse() async throws {
        // The Responses API enforces a forced tool server-side; the CLI protocol is prompt text,
        // so a stay_silent reply to the hint hotkey must not eat the hint.
        let workDir = try makeWorkDir()
        let c = client(.claudeCode, workDir: workDir) { _, _ in
            AgentCLIOutput(stdout: self.claudeEnvelope("""
            Try a hash map here.
            {"tool":"stay_silent","arguments":{}}
            """), stderr: "", exitCode: 0)
        }
        let response = try await c.respond(messages: [.user("help")], tools: coachTools,
                                           toolChoice: .force(speakTool.name))
        guard case .speak(_, let lines) = response.toolCalls.first else {
            Issue.record("expected forced speak, got \(response.toolCalls)"); return
        }
        #expect(lines == ["Try a hash map here."])
        // The recorded call must carry the lines actually shown — it's committed to session
        // history and replayed on later turns, so `speak({})` there would misreport the turn.
        #expect(response.rawToolCalls.first?.argumentsJSON.contains("Try a hash map here.") == true)
    }

    @Test func forcedSpeakWithNoUsableProseFallsSilent() async throws {
        // A wrong-tool reply with no prose has nothing worth rendering — silence over an empty tip.
        let workDir = try makeWorkDir()
        let c = client(.claudeCode, workDir: workDir) { _, _ in
            AgentCLIOutput(stdout: self.claudeEnvelope(#"{"tool":"stay_silent","arguments":{}}"#),
                           stderr: "", exitCode: 0)
        }
        let response = try await c.respond(messages: [.user("help")], tools: coachTools,
                                           toolChoice: .force(speakTool.name))
        #expect(response.toolCalls.isEmpty)
    }

    @Test func malformedSpeakArgumentsAreNotAnEmptySpokenTurn() async throws {
        // No Structured Outputs on the CLI path: {"tool":"speak","arguments":{}} must not become a
        // .speak with empty lines (an empty overlay that still counts as a spoken turn).
        let workDir = try makeWorkDir()
        let c = client(.claudeCode, workDir: workDir) { _, _ in
            AgentCLIOutput(stdout: self.claudeEnvelope(#"{"tool":"speak","arguments":{}}"#),
                           stderr: "", exitCode: 0)
        }
        let response = try await c.respond(messages: [.user("hm")], tools: coachTools,
                                           toolChoice: .required)
        #expect(response.toolCalls.isEmpty)
    }

    @Test func trafficRecordRedactsScreenshotsAndSpeaksTheEvaluatorSchema() async throws {
        // The audit record must carry instructions/input/reply in the evaluator's shape, with the
        // inline base64 image reduced to a stub — never the raw stream-json stdin, whose embedded
        // image bytes would slip past BrainTrafficLog's data:-URI redaction.
        let workDir = try makeWorkDir()
        let traffic = BrainTrafficLog()
        traffic.enable(directory: workDir)
        let base64 = Data("fake-jpeg-payload".utf8).base64EncodedString()
        let c = CLIBrainClient(provider: .claudeCode, executable: URL(fileURLWithPath: "/fake/bin/cli"),
                               model: "claude-sonnet-5", reasoningEffort: "low",
                               workDirectory: workDir,
                               traffic: traffic, trafficTag: "coach") { _, _ in
            AgentCLIOutput(stdout: self.claudeEnvelope(#"{"tool":"stay_silent","arguments":{}}"#),
                           stderr: "", exitCode: 0)
        }
        _ = try await c.respond(messages: [.system("coach prompt"), .user("look"), .userImage(base64)],
                                tools: coachTools, toolChoice: .required)
        let jsonl = try String(contentsOf: workDir.appendingPathComponent(BrainTrafficLog.filename),
                               encoding: .utf8)
        #expect(!jsonl.contains(base64))                    // no screenshot bytes in the audit log
        let entry = try #require(try JSONSerialization.jsonObject(
            with: Data(jsonl.split(separator: "\n").first.map(String.init)!.utf8)) as? [String: Any])
        let request = try #require(entry["request"] as? [String: Any])
        let instructions = try #require(request["instructions"] as? String)
        #expect(instructions.hasPrefix("coach prompt"))   // system text + the tool protocol
        let input = try #require(request["input"] as? [[String: Any]])
        #expect(input.contains { ($0["image"] as? String)?.contains("redacted") == true })
        let response = try #require(entry["response"] as? [String: Any])
        #expect((response["reply"] as? String)?.contains("stay_silent") == true)
    }

    // MARK: - Phase latency

    /// Read the single traffic line the run wrote.
    private func onlyTrafficEntry(in workDir: URL) throws -> [String: Any] {
        let jsonl = try String(contentsOf: workDir.appendingPathComponent(BrainTrafficLog.filename),
                               encoding: .utf8)
        let first = try #require(jsonl.split(separator: "\n").first.map(String.init))
        return try #require(try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
    }

    private func clientWithTraffic(_ provider: BrainProvider, workDir: URL,
                                   run: @escaping CLIBrainClient.Runner) -> (CLIBrainClient, BrainTrafficLog) {
        let traffic = BrainTrafficLog()
        traffic.enable(directory: workDir)
        let c = CLIBrainClient(provider: provider, executable: URL(fileURLWithPath: "/fake/bin/cli"),
                               model: "claude-sonnet-5", reasoningEffort: "low",
                               workDirectory: workDir,
                               traffic: traffic, trafficTag: "coach", run: run)
        return (c, traffic)
    }

    @Test func trafficRecordCarriesNamedPhaseLatencies() async throws {
        // A run that reaches every observable boundary records the full fixed set of named phases
        // (each an Int ms) — the same names for Claude and Codex, and the client-side parse phase.
        let workDir = try makeWorkDir()
        let (c, _) = clientWithTraffic(.claudeCode, workDir: workDir) { _, timings in
            timings.mark(.runnerEntered)
            timings.mark(.processLaunched)
            timings.mark(.stdinDelivered)
            timings.mark(.firstStdoutByte)
            timings.mark(.processExited)
            return AgentCLIOutput(stdout: self.claudeEnvelope(#"{"tool":"stay_silent","arguments":{}}"#),
                                  stderr: "", exitCode: 0)
        }
        _ = try await c.respond(messages: [.user("hi")], tools: coachTools, toolChoice: .required)
        let phases = try #require(try onlyTrafficEntry(in: workDir)["phases"] as? [String: Any])
        for key in [
            "queuedMs", "spawnMs", "stdinMs", "firstOutputMs", "outputMs", "parseMs", "totalMs",
        ] {
            #expect(phases[key] is Int, "expected \(key) to be a recorded Int ms")
        }
        let entry = try onlyTrafficEntry(in: workDir)
        #expect(entry["ms"] as? Int == phases["totalMs"] as? Int)
    }

    @Test func unobservedPhasesAreAbsentNotZero() async throws {
        // No stdout byte was ever seen, so the intervals that touch firstStdoutByte are omitted —
        // never recorded as a misleading zero — while the observed ones remain.
        let workDir = try makeWorkDir()
        let (c, _) = clientWithTraffic(.claudeCode, workDir: workDir) { _, timings in
            timings.mark(.runnerEntered)
            timings.mark(.processLaunched)
            timings.mark(.stdinDelivered)
            timings.mark(.processExited)   // no firstStdoutByte
            return AgentCLIOutput(stdout: self.claudeEnvelope("ok"), stderr: "", exitCode: 0)
        }
        _ = try await c.respond(messages: [.user("hi")], tools: coachTools, toolChoice: .required)
        let phases = try #require(try onlyTrafficEntry(in: workDir)["phases"] as? [String: Any])
        #expect(phases["firstOutputMs"] == nil)
        #expect(phases["outputMs"] == nil)
        #expect(phases["stdinMs"] is Int)
        #expect(phases["parseMs"] is Int)
        #expect(phases["totalMs"] is Int)
    }

    @Test func startupOutputBeforeStdinDeliveryStillRecordsFirstOutput() async throws {
        let workDir = try makeWorkDir()
        let (c, _) = clientWithTraffic(.claudeCode, workDir: workDir) { _, timings in
            timings.mark(.runnerEntered)
            timings.mark(.processLaunched)
            timings.mark(.firstStdoutByte)  // startup/progress event before the prompt write finishes
            timings.mark(.stdinDelivered)
            timings.mark(.processExited)
            return AgentCLIOutput(stdout: self.claudeEnvelope("ok"), stderr: "", exitCode: 0)
        }
        _ = try await c.respond(messages: [.user("hi")], tools: coachTools, toolChoice: .required)
        let phases = try #require(try onlyTrafficEntry(in: workDir)["phases"] as? [String: Any])
        #expect(phases["firstOutputMs"] is Int)
        #expect(phases["stdinMs"] is Int)
    }

    @Test func failedRunRecordsPhasesCompletedBeforeTheThrow() async throws {
        // A transport failure (the runner throws) still writes the phases finished before it, with
        // no response body — the timing up to the failure is not lost.
        let workDir = try makeWorkDir()
        let (c, _) = clientWithTraffic(.claudeCode, workDir: workDir) { _, timings in
            timings.mark(.runnerEntered)
            timings.mark(.processLaunched)
            throw CLIBrainClient.error("launch blew up")
        }
        await #expect(throws: BrainFailure.self) {
            _ = try await c.respond(messages: [.user("x")], tools: coachTools, toolChoice: .required)
        }
        let entry = try onlyTrafficEntry(in: workDir)
        #expect(entry["error"] != nil)
        #expect(entry["response"] == nil)
        let phases = try #require(entry["phases"] as? [String: Any])
        #expect(phases["spawnMs"] is Int)       // runnerEntered → processLaunched was observed
        #expect(phases["firstOutputMs"] == nil)  // never reached first output
        #expect(phases["parseMs"] == nil)        // reply was never parsed
        #expect(phases["totalMs"] is Int)
    }

    @Test func nonZeroExitRetainsCompletedPhasesButNotParse() async throws {
        let workDir = try makeWorkDir()
        let (c, _) = clientWithTraffic(.claudeCode, workDir: workDir) { _, timings in
            timings.mark(.runnerEntered)
            timings.mark(.processLaunched)
            timings.mark(.stdinDelivered)
            timings.mark(.processExited)
            return AgentCLIOutput(stdout: "", stderr: "not logged in", exitCode: 2)
        }
        await #expect(throws: BrainFailure.self) {
            _ = try await c.respond(messages: [.user("x")], tools: coachTools,
                                    toolChoice: .required)
        }
        let entry = try onlyTrafficEntry(in: workDir)
        #expect(entry["status"] as? Int == 500)
        #expect((entry["error"] as? String)?.contains("not logged in") == true)
        let phases = try #require(entry["phases"] as? [String: Any])
        #expect(phases["spawnMs"] is Int)
        #expect(phases["stdinMs"] is Int)
        #expect(phases["firstOutputMs"] == nil)
        #expect(phases["parseMs"] == nil)
        #expect(phases["totalMs"] is Int)
    }

    @Test func malformedFinalOutputStillRecordsPhases() async throws {
        // A clean exit whose stdout carries no usable protocol (the parse yields silence) must still
        // record the full observed timing, parse phase included.
        let workDir = try makeWorkDir()
        let (c, _) = clientWithTraffic(.claudeCode, workDir: workDir) { _, timings in
            timings.mark(.runnerEntered)
            timings.mark(.processLaunched)
            timings.mark(.stdinDelivered)
            timings.mark(.firstStdoutByte)
            timings.mark(.processExited)
            return AgentCLIOutput(stdout: "not json at all", stderr: "", exitCode: 0)
        }
        let response = try await c.respond(messages: [.user("hm")], tools: coachTools,
                                           toolChoice: .required)
        #expect(response.toolCalls.isEmpty)
        let phases = try #require(try onlyTrafficEntry(in: workDir)["phases"] as? [String: Any])
        #expect(phases["firstOutputMs"] is Int)
        #expect(phases["parseMs"] is Int)
        #expect(phases["totalMs"] is Int)
    }

    @Test func forcedSpeakDegradesToSpeakingTheRawReply() async throws {
        // A hotkey press must yield a visible hint even when the CLI forgets the JSON protocol.
        let workDir = try makeWorkDir()
        let c = client(.claudeCode, workDir: workDir) { _, _ in
            AgentCLIOutput(stdout: self.claudeEnvelope("Try a hash map.\nIt remembers seen values."),
                           stderr: "", exitCode: 0)
        }
        let response = try await c.respond(messages: [.user("help")], tools: coachTools,
                                           toolChoice: .force(speakTool.name))
        guard case .speak(_, let lines) = response.toolCalls.first else {
            Issue.record("expected speak fallback"); return
        }
        #expect(lines == ["Try a hash map.", "It remembers seen values."])
    }

    @Test func unparseableRequiredReplyIsSilenceNotACrash() async throws {
        let workDir = try makeWorkDir()
        let c = client(.claudeCode, workDir: workDir) { _, _ in
            AgentCLIOutput(stdout: self.claudeEnvelope("I have nothing structured to say."),
                           stderr: "", exitCode: 0)
        }
        let response = try await c.respond(messages: [.user("hm")], tools: coachTools,
                                           toolChoice: .required)
        #expect(response.toolCalls.isEmpty)
        #expect(response.outputText?.contains("nothing structured") == true)
    }

    // MARK: - Failures

    @Test func claudeErrorEnvelopeThrows() async throws {
        let workDir = try makeWorkDir()
        let c = client(.claudeCode, workDir: workDir) { _, _ in
            AgentCLIOutput(stdout: self.claudeEnvelope("credit balance too low", isError: true),
                           stderr: "", exitCode: 1)
        }
        await #expect(throws: BrainFailure.self) {
            _ = try await c.respond(messages: [.user("x")], tools: coachTools, toolChoice: .required)
        }
    }

    @Test func nonZeroExitWithoutEnvelopeThrowsWithStderr() async throws {
        let workDir = try makeWorkDir()
        let c = client(.claudeCode, workDir: workDir) { _, _ in
            AgentCLIOutput(stdout: "", stderr: "not logged in", exitCode: 2)
        }
        do {
            _ = try await c.respond(messages: [.user("x")], tools: coachTools, toolChoice: .required)
            Issue.record("expected a throw")
        } catch let failure as BrainFailure {
            #expect(failure.disposition == .temporary)
            #expect(failure.detail.contains("not logged in"))
        } catch {
            Issue.record("expected BrainFailure, got \(error)")
        }
    }
}
