import Foundation
import Testing
@testable import JarvisCore

@Suite struct CLIBrainClientTests {
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

    private func client(
        _ provider: BrainProvider,
        workDir: URL,
        model: String = "claude-sonnet-5",
        effort: String = "low",
        codexFeaturesToDisable: Set<String> = [],
        run: @escaping CLIBrainClient.Runner
    ) -> CLIBrainClient {
        CLIBrainClient(
            provider: provider,
            executable: URL(fileURLWithPath: "/fake/bin/cli"),
            model: model,
            reasoningEffort: effort,
            workDirectory: workDir,
            codexFeaturesToDisable: codexFeaturesToDisable,
            run: run)
    }

    private func mcpConfiguration(
        for provider: BrainProvider,
        in directory: URL
    ) -> CLIMCPConfiguration {
        CLIMCPConfiguration(
            serverExecutable: URL(fileURLWithPath: "/bundle/JarvisMCPServer"),
            ticketFile: directory.appendingPathComponent("attempt.ticket.json"),
            claudeConfigFile: provider == .claudeCode
                ? directory.appendingPathComponent("attempt.claude.json")
                : nil)
    }

    @Test func directToolCallIsRejectedBeforeTheCLIStarts() async throws {
        let workDir = try makeWorkDir()
        let ran = Captured<Bool>()
        let c = client(.claudeCode, workDir: workDir) { _, _ in
            ran.value = true
            return AgentCLIOutput(stdout: "", stderr: "", exitCode: 0)
        }

        do {
            _ = try await c.respond(
                messages: [.user("coach me")],
                tools: coachTools,
                toolChoice: .required)
            Issue.record("toolful CLI call bypassed MCP")
        } catch let failure as BrainFailure {
            #expect(failure.disposition == .permanent)
            #expect(failure.detail.contains("require MCP"))
        }
        #expect(ran.value == nil)
    }

    @Test func claudeMCPRunLoadsOnlyThePrivateServerAndDoesNotRequestOutputJSON() async throws {
        let workDir = try makeWorkDir()
        let captured = Captured<AgentCLIRun>()
        let completion = AgentCLICompletionSignal()
        let c = client(.claudeCode, workDir: workDir) { run, _ in
            captured.value = run
            return AgentCLIOutput(
                stdout: self.claudeEnvelope("tool calls completed"),
                stderr: "",
                exitCode: 0)
        }

        let response = try await c.respondUsingMCP(
            messages: [.system("coach prompt"), .user("look first")],
            tools: [speakTool],
            toolChoice: .force(speakTool.name),
            configuration: mcpConfiguration(for: .claudeCode, in: workDir),
            completionSignal: completion)

        let run = try #require(captured.value)
        #expect(run.completionSignal === completion)
        #expect(run.completionEvidence == .stdoutJSONToolResult(
            toolNames: ["mcp__jarvis__speak"],
            acceptedText: terminalActionAcceptedText))
        #expect(run.arguments.contains("-p"))
        #expect(run.arguments.contains("stream-json"))
        #expect(run.arguments.contains("claude-sonnet-5"))
        #expect(run.arguments.contains("--setting-sources"))
        #expect(run.arguments.contains("--no-session-persistence"))
        let configIndex = try #require(run.arguments.firstIndex(of: "--mcp-config"))
        #expect(run.arguments[configIndex + 1].hasSuffix("attempt.claude.json"))
        #expect(run.arguments.contains("--strict-mcp-config"))
        #expect(run.arguments.contains("mcp__jarvis__speak"))
        #expect(!run.arguments.contains("mcp__jarvis__capture_screen"))
        #expect(!run.arguments.contains("mcp__jarvis__stay_silent"))
        let maxTurnsIndex = try #require(run.arguments.firstIndex(of: "--max-turns"))
        #expect(run.arguments[maxTurnsIndex + 1] == "1")
        let promptIndex = try #require(run.arguments.firstIndex(of: "--system-prompt"))
        let instructions = run.arguments[promptIndex + 1]
        #expect(instructions.contains("callable tools"))
        #expect(instructions.contains("Ignore every built-in"))
        #expect(instructions.contains("Do not call any action that is not listed above."))
        #expect(!instructions.contains("capture_screen at most once"))
        #expect(instructions.contains("exactly one `speak` action"))
        #expect(!instructions.contains(#"{"tool":"<tool name>""#))
        let effortIndex = try #require(run.arguments.firstIndex(of: "--effort"))
        #expect(run.arguments[effortIndex + 1] == "low")
        let toolsIndex = try #require(run.arguments.firstIndex(of: "--tools"))
        #expect(run.arguments[toolsIndex + 1] == "")
        #expect(run.stdin?.contains("look first") == true)
        #expect(response.actionDelivery == .broker)
        #expect(response.toolCalls.isEmpty)
    }

    @Test func codexMCPRunReplacesInheritedServersAndDerivesEnabledTools() async throws {
        let workDir = try makeWorkDir()
        let captured = Captured<AgentCLIRun>()
        let c = client(
            .codexCLI,
            workDir: workDir,
            model: "gpt-5.6-sol",
            codexFeaturesToDisable: ["shell_tool", "future-surface"]
        ) { run, _ in
            captured.value = run
            if let index = run.arguments.firstIndex(of: "--output-last-message") {
                try "tool calls completed".write(
                    toFile: run.arguments[index + 1],
                    atomically: true,
                    encoding: .utf8)
            }
            return AgentCLIOutput(stdout: "codex log", stderr: "", exitCode: 0)
        }

        let response = try await c.respondUsingMCP(
            messages: [.system("coach prompt"), .user("look first")],
            tools: [captureScreenTool, staySilentTool],
            toolChoice: .force(staySilentTool.name),
            configuration: mcpConfiguration(for: .codexCLI, in: workDir))

        let run = try #require(captured.value)
        #expect(run.arguments.contains {
            $0 == #"mcp_servers.jarvis.command="/bundle/JarvisMCPServer""#
        })
        #expect(run.arguments.contains(
            #"mcp_servers.jarvis.enabled_tools=["capture_screen","stay_silent"]"#))
        #expect(run.arguments.contains(
            #"mcp_servers.jarvis.default_tools_approval_mode="approve""#))
        #expect(run.arguments.contains("mcp_servers={}"))
        let modelIndex = try #require(run.arguments.firstIndex(of: "-m"))
        #expect(run.arguments[modelIndex + 1] == "gpt-5.6-sol")
        let disabledFeatures = zip(run.arguments, run.arguments.dropFirst()).compactMap {
            flag, value in flag == "--disable" ? value : nil
        }
        #expect(disabledFeatures == ["future-surface", "shell_tool"])
        #expect(run.stdin?.contains("callable tools") == true)
        #expect(run.stdin?.contains("Ignore every built-in") == true)
        #expect(run.stdin?.contains("capture_screen at most once") == true)
        #expect(run.stdin?.contains("exactly one terminal tool") == true)
        #expect(!run.stdin!.contains(#"{"tool":"<tool name>""#))
        #expect(response.actionDelivery == .broker)
    }

    @Test func claudeMCPScreenshotRidesInlineAsAnImageBlock() async throws {
        let workDir = try makeWorkDir()
        let base64 = Data("fake-jpeg".utf8).base64EncodedString()
        let observed = Captured<(files: [String], run: AgentCLIRun)>()
        let c = client(.claudeCode, workDir: workDir) { run, _ in
            observed.value = (
                files: try FileManager.default.contentsOfDirectory(atPath: workDir.path),
                run: run)
            return AgentCLIOutput(
                stdout: self.claudeEnvelope("tool calls completed"),
                stderr: "",
                exitCode: 0)
        }

        _ = try await c.respondUsingMCP(
            messages: [.user("look"), .userImage(base64)],
            tools: coachTools,
            toolChoice: .required,
            configuration: mcpConfiguration(for: .claudeCode, in: workDir))

        let seen = try #require(observed.value)
        #expect(seen.files.isEmpty)
        let maxTurnsIndex = try #require(seen.run.arguments.firstIndex(of: "--max-turns"))
        #expect(seen.run.arguments[maxTurnsIndex + 1] == "2")
        let message = try #require(try JSONSerialization.jsonObject(
            with: Data((seen.run.stdin ?? "").utf8)) as? [String: Any])
        let content = try #require(
            (message["message"] as? [String: Any])?["content"] as? [[String: Any]])
        let imageBlock = try #require(content.first { $0["type"] as? String == "image" })
        #expect((imageBlock["source"] as? [String: Any])?["data"] as? String == base64)
        #expect(content.contains {
            ($0["text"] as? String)?.contains("look") == true
        })
    }

    @Test func codexMCPScreenshotRidesAsImageFlag() async throws {
        let workDir = try makeWorkDir()
        let base64 = Data("fake-jpeg".utf8).base64EncodedString()
        let captured = Captured<AgentCLIRun>()
        let c = client(.codexCLI, workDir: workDir, model: "gpt-5.6-sol") { run, _ in
            captured.value = run
            if let index = run.arguments.firstIndex(of: "--output-last-message") {
                try "tool calls completed".write(
                    toFile: run.arguments[index + 1],
                    atomically: true,
                    encoding: .utf8)
            }
            return AgentCLIOutput(stdout: "codex log noise", stderr: "", exitCode: 0)
        }

        _ = try await c.respondUsingMCP(
            messages: [.userImage(base64)],
            tools: coachTools,
            toolChoice: .required,
            configuration: mcpConfiguration(for: .codexCLI, in: workDir))

        let run = try #require(captured.value)
        #expect(run.arguments.contains("exec"))
        #expect(run.arguments.contains("--ephemeral"))
        #expect(run.arguments.contains("--ignore-user-config"))
        #expect(run.arguments.contains("--ignore-rules"))
        #expect(run.arguments.contains("project_root_markers=[]"))
        #expect(run.arguments.contains("project_doc_max_bytes=0"))
        #expect(run.timeout == CLIBrainClient.codexDefaultTimeout)
        #expect(run.arguments.contains("-i"))
        let modelIndex = try #require(run.arguments.firstIndex(of: "-m"))
        #expect(run.arguments[modelIndex + 1] == "gpt-5.6-sol")
        #expect(try FileManager.default.contentsOfDirectory(atPath: workDir.path).isEmpty)
    }

    @Test func codexToolLessRunDoesNotApplyTheCoachingFeatureProfile() async throws {
        let workDir = try makeWorkDir()
        let captured = Captured<AgentCLIRun>()
        let c = client(
            .codexCLI,
            workDir: workDir,
            model: "",
            codexFeaturesToDisable: ["z_future_surface", "apps"]
        ) { run, _ in
            captured.value = run
            if let index = run.arguments.firstIndex(of: "--output-last-message") {
                try "summary".write(
                    toFile: run.arguments[index + 1],
                    atomically: true,
                    encoding: .utf8)
            }
            return AgentCLIOutput(stdout: "", stderr: "", exitCode: 0)
        }

        _ = try await c.respond(messages: [.user("summarize")], tools: [], toolChoice: .auto)

        let run = try #require(captured.value)
        let disabledFeatures = zip(run.arguments, run.arguments.dropFirst()).compactMap {
            flag, value in flag == "--disable" ? value : nil
        }
        #expect(disabledFeatures.isEmpty)
    }

    @Test func codexEmptyDetectedFeatureSetKeepsTheMCPRestrictionsAndFastPath() async throws {
        let workDir = try makeWorkDir()
        let captured = Captured<AgentCLIRun>()
        let completion = AgentCLICompletionSignal()
        let c = client(.codexCLI, workDir: workDir, model: "") { run, _ in
            captured.value = run
            if let index = run.arguments.firstIndex(of: "--output-last-message") {
                try "tool calls completed".write(
                    toFile: run.arguments[index + 1],
                    atomically: true,
                    encoding: .utf8)
            }
            return AgentCLIOutput(stdout: "", stderr: "", exitCode: 0)
        }

        _ = try await c.respondUsingMCP(
            messages: [.user("coach me")],
            tools: [speakTool],
            toolChoice: .force(speakTool.name),
            configuration: mcpConfiguration(for: .codexCLI, in: workDir),
            completionSignal: completion)

        let run = try #require(captured.value)
        #expect(!run.arguments.contains("--disable"))
        #expect(run.arguments.contains("--sandbox"))
        #expect(run.arguments.contains("read-only"))
        #expect(run.arguments.contains("--ephemeral"))
        #expect(run.arguments.contains("mcp_servers.jarvis.enabled_tools=[\"speak\"]"))
        #expect(run.stdin?.contains("Ignore every non-Jarvis tool") == true)
        #expect(run.completionSignal === completion)
        #expect(run.completionEvidence == .signal)
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

    @Test func toolLessCallReturnsPlainText() async throws {
        let workDir = try makeWorkDir()
        let c = client(.claudeCode, workDir: workDir) { _, _ in
            AgentCLIOutput(
                stdout: self.claudeEnvelope("a tidy briefing"),
                stderr: "",
                exitCode: 0)
        }
        let response = try await c.respond(
            messages: [.system("summarize"), .user("stuff")],
            tools: [],
            toolChoice: .auto)
        #expect(response.outputText == "a tidy briefing")
        #expect(response.toolCalls.isEmpty)
    }

    @Test func trafficRecordRedactsMCPScreenshotsAndUsesTheEvaluatorSchema() async throws {
        let workDir = try makeWorkDir()
        let traffic = BrainTrafficLog()
        traffic.enable(directory: workDir)
        let base64 = Data("fake-jpeg-payload".utf8).base64EncodedString()
        let c = CLIBrainClient(
            provider: .claudeCode,
            executable: URL(fileURLWithPath: "/fake/bin/cli"),
            model: "claude-sonnet-5",
            reasoningEffort: "low",
            workDirectory: workDir,
            traffic: traffic,
            trafficTag: "coach"
        ) { _, _ in
            AgentCLIOutput(
                stdout: self.claudeEnvelope("tool calls completed"),
                stderr: "",
                exitCode: 0)
        }

        _ = try await c.respondUsingMCP(
            messages: [.system("coach prompt"), .user("look"), .userImage(base64)],
            tools: coachTools,
            toolChoice: .required,
            configuration: mcpConfiguration(for: .claudeCode, in: workDir))

        let jsonl = try String(
            contentsOf: workDir.appendingPathComponent(BrainTrafficLog.filename),
            encoding: .utf8)
        #expect(!jsonl.contains(base64))
        let entry = try #require(try JSONSerialization.jsonObject(
            with: Data(jsonl.split(separator: "\n").first.map(String.init)!.utf8))
            as? [String: Any])
        let request = try #require(entry["request"] as? [String: Any])
        #expect(request["actionTransport"] as? String == "mcp")
        #expect((request["instructions"] as? String)?.hasPrefix("coach prompt") == true)
        let input = try #require(request["input"] as? [[String: Any]])
        #expect(input.contains { ($0["image"] as? String)?.contains("redacted") == true })
    }

    @Test func acknowledgedCodexTerminalStopSkipsReplyParsingAndRecordsCompletion() async throws {
        let workDir = try makeWorkDir()
        let completion = AgentCLICompletionSignal()
        let c = clientWithTraffic(.codexCLI, workDir: workDir) { run, timings in
            #expect(run.completionSignal === completion)
            #expect(run.completionEvidence == .signal)
            timings.mark(.runnerEntered)
            timings.mark(.processLaunched)
            timings.mark(.stdinDelivered)
            timings.mark(.firstStdoutByte)
            timings.mark(.processExited)
            #expect(completion.signal(.terminalActionDelivered))
            return AgentCLIOutput(
                stdout: "partial codex diagnostics",
                stderr: "",
                exitCode: 15,
                termination: .completionSignal(.terminalActionDelivered))
        }

        let response = try await c.respondUsingMCP(
            messages: [.user("coach me")],
            tools: [speakTool],
            toolChoice: .force(speakTool.name),
            configuration: mcpConfiguration(for: .codexCLI, in: workDir),
            completionSignal: completion)

        #expect(response.actionDelivery == .broker)
        #expect(response.outputText == nil)
        let entry = try onlyTrafficEntry(in: workDir)
        #expect(entry["status"] as? Int == 200)
        let recorded = try #require(entry["response"] as? [String: Any])
        #expect(recorded["completion"] as? String == "terminalActionDelivered")
        #expect(recorded["exitCode"] as? Int == 15)
        #expect(recorded["reply"] == nil)
        let phases = try #require(entry["phases"] as? [String: Any])
        #expect(phases["parseMs"] == nil)
    }

    @Test func acknowledgedClaudeTerminalStopSkipsFinalEnvelopeAndRecordsCompletion() async throws {
        let workDir = try makeWorkDir()
        let completion = AgentCLICompletionSignal()
        let c = clientWithTraffic(.claudeCode, workDir: workDir) { run, timings in
            #expect(run.completionSignal === completion)
            #expect(run.completionEvidence == .stdoutJSONToolResult(
                toolNames: ["mcp__jarvis__speak"],
                acceptedText: terminalActionAcceptedText))
            timings.mark(.runnerEntered)
            timings.mark(.processLaunched)
            timings.mark(.stdinDelivered)
            timings.mark(.firstStdoutByte)
            timings.mark(.processExited)
            #expect(completion.signal(.terminalActionDelivered))
            return AgentCLIOutput(
                stdout: #"{"type":"assistant","message":{"content":[{"type":"tool_use"}]}}"#,
                stderr: "",
                exitCode: 15,
                termination: .completionSignal(.terminalActionDelivered))
        }

        let response = try await c.respondUsingMCP(
            messages: [.user("coach me")],
            tools: [speakTool],
            toolChoice: .force(speakTool.name),
            configuration: mcpConfiguration(for: .claudeCode, in: workDir),
            completionSignal: completion)

        #expect(response.actionDelivery == .broker)
        #expect(response.outputText == nil)
        let entry = try onlyTrafficEntry(in: workDir)
        #expect(entry["status"] as? Int == 200)
        let recorded = try #require(entry["response"] as? [String: Any])
        #expect(recorded["completion"] as? String == "terminalActionDelivered")
        #expect(recorded["exitCode"] as? Int == 15)
        #expect(recorded["reply"] == nil)
        #expect(recorded["cli"] == nil)
        let phases = try #require(entry["phases"] as? [String: Any])
        #expect(phases["parseMs"] == nil)
    }

    private func onlyTrafficEntry(in workDir: URL) throws -> [String: Any] {
        let jsonl = try String(
            contentsOf: workDir.appendingPathComponent(BrainTrafficLog.filename),
            encoding: .utf8)
        let first = try #require(jsonl.split(separator: "\n").first.map(String.init))
        return try #require(
            try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
    }

    private func clientWithTraffic(
        _ provider: BrainProvider,
        workDir: URL,
        run: @escaping CLIBrainClient.Runner
    ) -> CLIBrainClient {
        let traffic = BrainTrafficLog()
        traffic.enable(directory: workDir)
        return CLIBrainClient(
            provider: provider,
            executable: URL(fileURLWithPath: "/fake/bin/cli"),
            model: "claude-sonnet-5",
            reasoningEffort: "low",
            workDirectory: workDir,
            traffic: traffic,
            trafficTag: "coach",
            run: run)
    }

    @Test func trafficRecordCarriesNamedPhaseLatencies() async throws {
        let workDir = try makeWorkDir()
        let c = clientWithTraffic(.claudeCode, workDir: workDir) { _, timings in
            timings.mark(.runnerEntered)
            timings.mark(.processLaunched)
            timings.mark(.stdinDelivered)
            timings.mark(.firstStdoutByte)
            timings.mark(.processExited)
            return AgentCLIOutput(
                stdout: self.claudeEnvelope("done"),
                stderr: "",
                exitCode: 0)
        }
        _ = try await c.respond(messages: [.user("hi")], tools: [], toolChoice: .auto)
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
        let workDir = try makeWorkDir()
        let c = clientWithTraffic(.claudeCode, workDir: workDir) { _, timings in
            timings.mark(.runnerEntered)
            timings.mark(.processLaunched)
            timings.mark(.stdinDelivered)
            timings.mark(.processExited)
            return AgentCLIOutput(
                stdout: self.claudeEnvelope("ok"),
                stderr: "",
                exitCode: 0)
        }
        _ = try await c.respond(messages: [.user("hi")], tools: [], toolChoice: .auto)
        let phases = try #require(try onlyTrafficEntry(in: workDir)["phases"] as? [String: Any])
        #expect(phases["firstOutputMs"] == nil)
        #expect(phases["outputMs"] == nil)
        #expect(phases["stdinMs"] is Int)
        #expect(phases["parseMs"] is Int)
        #expect(phases["totalMs"] is Int)
    }

    @Test func failedRunRecordsPhasesCompletedBeforeTheThrow() async throws {
        let workDir = try makeWorkDir()
        let c = clientWithTraffic(.claudeCode, workDir: workDir) { _, timings in
            timings.mark(.runnerEntered)
            timings.mark(.processLaunched)
            throw CLIBrainClient.error("launch blew up")
        }
        await #expect(throws: BrainFailure.self) {
            _ = try await c.respond(messages: [.user("x")], tools: [], toolChoice: .auto)
        }
        let entry = try onlyTrafficEntry(in: workDir)
        #expect(entry["error"] != nil)
        #expect(entry["response"] == nil)
        let phases = try #require(entry["phases"] as? [String: Any])
        #expect(phases["spawnMs"] is Int)
        #expect(phases["firstOutputMs"] == nil)
        #expect(phases["parseMs"] == nil)
        #expect(phases["totalMs"] is Int)
    }

    @Test func nonZeroExitRetainsCompletedPhasesButNotParse() async throws {
        let workDir = try makeWorkDir()
        let c = clientWithTraffic(.claudeCode, workDir: workDir) { _, timings in
            timings.mark(.runnerEntered)
            timings.mark(.processLaunched)
            timings.mark(.stdinDelivered)
            timings.mark(.processExited)
            return AgentCLIOutput(stdout: "", stderr: "not logged in", exitCode: 2)
        }
        await #expect(throws: BrainFailure.self) {
            _ = try await c.respond(messages: [.user("x")], tools: [], toolChoice: .auto)
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

    @Test func claudeErrorEnvelopeThrows() async throws {
        let workDir = try makeWorkDir()
        let c = client(.claudeCode, workDir: workDir) { _, _ in
            AgentCLIOutput(
                stdout: self.claudeEnvelope("credit balance too low", isError: true),
                stderr: "",
                exitCode: 1)
        }
        await #expect(throws: BrainFailure.self) {
            _ = try await c.respond(messages: [.user("x")], tools: [], toolChoice: .auto)
        }
    }

    @Test func nonZeroExitWithoutEnvelopeThrowsWithStderr() async throws {
        let workDir = try makeWorkDir()
        let c = client(.claudeCode, workDir: workDir) { _, _ in
            AgentCLIOutput(stdout: "", stderr: "not logged in", exitCode: 2)
        }
        do {
            _ = try await c.respond(messages: [.user("x")], tools: [], toolChoice: .auto)
            Issue.record("expected a throw")
        } catch let failure as BrainFailure {
            #expect(failure.disposition == .temporary)
            #expect(failure.detail.contains("not logged in"))
        } catch {
            Issue.record("expected BrainFailure, got \(error)")
        }
    }
}
