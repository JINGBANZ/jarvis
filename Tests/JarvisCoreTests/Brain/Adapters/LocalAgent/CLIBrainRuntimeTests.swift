import Darwin
import Foundation
import Testing
@testable import JarvisCore

@Suite(.serialized) struct CLIBrainRuntimeTests {
    @Test func runtimeSetEncapsulatesProviderSpecificSharing() {
        let sharedCodex = CLIBrainRuntime(provider: .codexCLI)
        let codex = LocalAgentRuntimeSet(provider: .codexCLI, sharedCoach: sharedCodex)
        #expect(codex.coach === sharedCodex)
        #expect(codex.summarizer === sharedCodex)

        let claude = LocalAgentRuntimeSet(provider: .claudeCode)
        #expect(claude.coach !== claude.summarizer)
    }

    @Test func cancellingClaudePreparationStopsTheInitializingProcess() async throws {
        try await assertCancellingPreparationStopsProcess(provider: .claudeCode)
    }

    @Test func cancellingCodexPreparationStopsTheInitializingProcess() async throws {
        try await assertCancellingPreparationStopsProcess(provider: .codexCLI)
    }

    @Test func claudeLaunchUsesOAuthCompatibleCustomizationAndToolIsolation() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let argumentsFile = directory.appendingPathComponent("arguments")
        let executable = try makeExecutable(
            in: directory,
            named: "fake-claude",
            script: """
                #!/bin/sh
                printf 'arg=<%s>\\n' "$@" > '\(shellQuoted(argumentsFile.path))'
                while IFS= read -r line; do
                  case "$line" in
                    *'"type":"control_request"'*)
                      request_id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
                      printf '{"type":"control_response","response":{"request_id":"%s","subtype":"success"}}\\n' "$request_id"
                      ;;
                  esac
                done
                """)
        let runtime = CLIBrainRuntime(provider: .claudeCode)
        let client = makeClient(
            provider: .claudeCode,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: false)

        let conversation = try await client.makeConversation()
        await conversation.finish()
        try await waitForFile(argumentsFile)
        runtime.terminateNow()

        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .map { String($0.dropFirst("arg=<".count).dropLast()) }
        #expect(arguments.contains("--safe-mode"))
        #expect(!arguments.contains("--bare"))
        #expect(containsPair("--tools", "", in: arguments))
        #expect(containsPair("--setting-sources", "", in: arguments))
        #expect(containsPair("--mcp-config", #"{"mcpServers":{}}"#, in: arguments))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("--no-session-persistence"))
    }

    @Test func codexFailsClosedBeforeLaunchDespiteEmptyOrDriftedFeatureDiscovery() async throws {
        for supportedFeatures: Set<String> in [
            [],
            ["shell_tool", "unified_exec"],
            ["future_tool_family_unknown_to_jarvis"],
        ] {
            let directory = try makeWorkDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let launched = directory.appendingPathComponent("launched")
            let executable = try makeExecutable(
                in: directory,
                named: "fake-codex",
                script: """
                    #!/bin/sh
                    printf 'launched\\n' > '\(shellQuoted(launched.path))'
                    sleep 30
                    """)
            let runtimeBaseDirectory = directory.appendingPathComponent("agent-runtimes")
            let runtime = CLIBrainRuntime(
                provider: .codexCLI,
                codexRuntimeBaseDirectory: runtimeBaseDirectory,
                codexSupportedFeatures: supportedFeatures)
            let client = makeClient(
                provider: .codexCLI,
                executable: executable,
                directory: directory,
                runtime: runtime,
                prewarm: false)

            do {
                _ = try await client.makeConversation()
                Issue.record("expected Codex tool-isolation refusal")
            } catch {
                let failure = try #require(error as? BrainFailure)
                #expect(failure.disposition == .permanent)
                #expect(failure.detail.contains("does not expose a stable mode"))
            }
            #expect(!FileManager.default.fileExists(atPath: launched.path))
            #expect(!FileManager.default.fileExists(atPath: runtimeBaseDirectory.path))
            runtime.terminateNow()
        }
    }

    @Test func overlappingClaudePrewarmInstallsOneQueryAndKeepsItsReplacement() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launches = directory.appendingPathComponent("launches")
        let executable = try makeExecutable(
            in: directory,
            named: "fake-claude",
            script: """
                #!/bin/sh
                printf 'launch\\n' >> '\(shellQuoted(launches.path))'
                while IFS= read -r line; do
                  case "$line" in
                    *'"type":"control_request"'*)
                      request_id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
                      sleep 0.2
                      printf '{"type":"control_response","response":{"request_id":"%s","subtype":"success"}}\\n' "$request_id"
                      ;;
                  esac
                done
                """)
        let runtime = CLIBrainRuntime(provider: .claudeCode)
        let client = makeClient(
            provider: .claudeCode,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: true)

        let first = try await client.makeConversation()
        await first.finish()
        let second = try await client.makeConversation()
        await second.finish()
        try await waitForLineCount(3, in: launches)
        try await Task.sleep(nanoseconds: 300_000_000)

        let count = try String(contentsOf: launches, encoding: .utf8)
            .split(separator: "\n").count
        #expect(count == 3)
        runtime.terminateNow()
    }

    @Test func codexRejectsUnknownThreadItemTypes() async throws {
        try await assertCodexRejects(event: """
            {"method":"item/started","params":{"threadId":"thread-1","item":{"type":"imageView"}}}
            """, expectedDetail: "disallowed item event")
    }

    @Test func codexRejectsEveryServerRequest() async throws {
        try await assertCodexRejects(event: """
            {"id":99,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1"}}
            """, expectedDetail: "unexpected server request")
    }

    @Test func codexRejectsDisallowedItemsInTheCompletedTurnSnapshot() async throws {
        try await assertCodexRejects(event: """
            {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"status":"completed","items":[{"type":"sleep"}]}}}
            """, expectedDetail: "disallowed item")
    }

    @Test func codexUnsubscribeUsesItsCleanupDeadline() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            named: "fake-codex",
            script: """
                #!/bin/sh
                while IFS= read -r line; do
                  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
                  method=$(printf '%s' "$line" | sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p' | tr -d '\\\\')
                  case "$method" in
                    initialize)
                      printf '{"id":%s,"result":{}}\\n' "$request_id"
                      ;;
                    thread/start)
                      printf '{"id":%s,"result":{"thread":{"id":"thread-1","ephemeral":true,"path":null},"instructionSources":[]}}\\n' "$request_id"
                      ;;
                    turn/start)
                      printf '%s\\n' '{"method":"item/completed","params":{"threadId":"thread-1","item":{"type":"agentMessage","text":"{\\"tool\\":\\"stay_silent\\",\\"arguments\\":{}}"}}}'
                      printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"status":"completed","items":[{"type":"agentMessage"}]}}}'
                      ;;
                    thread/unsubscribe)
                      sleep 30
                      ;;
                  esac
                done
                """)
        let runtime = makeRuntime(provider: .codexCLI, directory: directory)
        let client = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: false)

        let started = Date()
        let response = try await client.respond(
            messages: [.system("coach prompt"), .user("help")],
            tools: coachTools,
            toolChoice: .required)

        guard case .staySilent = try #require(response.toolCalls.first) else {
            Issue.record("expected stay_silent")
            return
        }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    private func assertCancellingPreparationStopsProcess(
        provider: BrainProvider
    ) async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let executable = try makeExecutable(
            in: directory,
            named: "blocked-agent",
            script: """
                #!/bin/sh
                printf '%s\\n' "$$" > '\(shellQuoted(pidFile.path))'
                while IFS= read -r line; do :; done
                """)
        let runtime = makeRuntime(provider: provider, directory: directory)
        let client = makeClient(
            provider: provider,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: false)
        let task = Task {
            try await client.makeConversation()
        }
        try await waitForFile(pidFile)
        let pid = try #require(
            pid_t(String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))

        let cancelledAt = Date()
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("expected cancelled preparation")
            return
        }
        #expect(error is CancellationError)
        #expect(Date().timeIntervalSince(cancelledAt) < 2)
        try await waitForProcessExit(pid)
        #expect(kill(pid, 0) == -1)
    }

    private func assertCodexRejects(event: String, expectedDetail: String) async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = directory.appendingPathComponent("trace")
        let executable = try makeExecutable(
            in: directory,
            named: "fake-codex",
            script: """
                #!/bin/sh
                while IFS= read -r line; do
                  printf 'input: %s\\n' "$line" >> '\(shellQuoted(trace.path))'
                  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
                  method=$(printf '%s' "$line" | sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p' | tr -d '\\\\')
                  case "$method" in
                    initialize)
                      printf '{"id":%s,"result":{}}\\n' "$request_id"
                      ;;
                    thread/start)
                      printf '{"id":%s,"result":{"thread":{"id":"thread-1","ephemeral":true,"path":null},"instructionSources":[]}}\\n' "$request_id"
                      ;;
                    turn/start)
                      printf 'event: %s\\n' '\(shellQuoted(event))' >> '\(shellQuoted(trace.path))'
                      printf '%s\\n' '\(shellQuoted(event))'
                      ;;
                  esac
                done
                """)
        let runtime = makeRuntime(provider: .codexCLI, directory: directory)
        let client = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: false)

        do {
            _ = try await client.respond(
                messages: [.system("coach prompt"), .user("help")],
                tools: coachTools,
                toolChoice: .required)
            Issue.record("expected Codex event rejection")
        } catch {
            if !error.localizedDescription.contains(expectedDetail) {
                let traceText = (try? String(contentsOf: trace, encoding: .utf8)) ?? "(no trace)"
                Issue.record(
                    "expected \(expectedDetail), got \(error.localizedDescription); \(traceText)")
            }
        }
        runtime.terminateNow()
    }

    private func makeClient(
        provider: BrainProvider,
        executable: URL,
        directory: URL,
        runtime: CLIBrainRuntime,
        prewarm: Bool
    ) -> CLIBrainClient {
        CLIBrainClient(
            provider: provider,
            executable: executable,
            model: "",
            workDirectory: directory,
            timeout: 10,
            systemPrompt: "coach prompt",
            tools: coachTools,
            toolChoice: .required,
            runtime: runtime,
            prewarm: prewarm)
    }

    private func makeWorkDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBrainRuntimeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        return directory
    }

    private func makeRuntime(provider: BrainProvider, directory: URL) -> CLIBrainRuntime {
        if provider == .codexCLI {
            // Exercise the dormant app-server protocol guards with a fake future provider control.
            // Normal product construction never supplies this evidence and therefore never launches.
            return CLIBrainRuntime(
                backend: CodexAppServerRuntime(
                    runtimeBaseDirectory: directory.appendingPathComponent("agent-runtimes"),
                    builtInToolIsolation: .toolFree(
                        launchArguments: ["--fake-test-only-no-built-in-tools"])))
        }
        return CLIBrainRuntime(
            provider: provider,
            codexRuntimeBaseDirectory: directory.appendingPathComponent("agent-runtimes"))
    }

    private func makeExecutable(in directory: URL, named name: String, script: String) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path)
        return executable
    }

    private func waitForFile(_ file: URL) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try #require(FileManager.default.fileExists(atPath: file.path))
    }

    private func waitForLineCount(_ expected: Int, in file: URL) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               text.split(separator: "\n").count >= expected {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("timed out waiting for \(expected) launches")
    }

    private func waitForProcessExit(_ pid: pid_t) async throws {
        let deadline = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func shellQuoted(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func containsPair(_ first: String, _ second: String, in arguments: [String]) -> Bool {
        arguments.indices.dropLast().contains {
            arguments[$0] == first && arguments[$0 + 1] == second
        }
    }
}
