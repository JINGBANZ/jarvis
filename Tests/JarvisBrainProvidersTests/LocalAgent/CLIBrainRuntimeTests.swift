import Darwin
import Foundation
import Testing
@testable import JarvisBrainProviders
import JarvisCore

@Suite(.serialized) struct CLIBrainRuntimeTests {
    /// The summarizer never shares the coach's runtime, for either provider. Codex's app-server
    /// admits one conversation at a time, so a shared runtime let an off-path summary fail the next
    /// coaching attempt — and three counted failures exhaust the target and advance the route.
    /// Compaction must not be able to cost a brain provider.
    @Test func runtimeSetNeverSharesTheCoachRuntimeWithTheSummarizer() {
        let sharedCodex = CLIBrainRuntime(provider: .codexCLI)
        let codex = LocalAgentRuntimeSet(provider: .codexCLI, sharedCoach: sharedCodex)
        #expect(codex.coach === sharedCodex)
        #expect(codex.summarizer !== sharedCodex)

        let claude = LocalAgentRuntimeSet(provider: .claudeCode)
        #expect(claude.coach !== claude.summarizer)
    }

    /// The one-shot path carries the same control the app-server does. `wiki/decisions.md` records
    /// that Codex's `--disable` flags narrow nothing — `exec`, `wait`, `request_user_input`, and
    /// `collaboration` are offered either way — so the item-event allowlist is what actually bites.
    /// Without it a prompt injection riding in transcript or OCR text could get a background summary
    /// to run a built-in tool during the live pipeline.
    @Test func codexExecAbortsOnAToolItemEvent() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = directory.appendingPathComponent("trace")
        let executable = try makeExecutable(
            in: directory,
            named: "fake-codex",
            script: codexScript(
                trace: trace,
                threadResult: Self.ephemeralThreadResult,
                execReply: "condensed briefing",
                execItemType: "command_execution"))
        let runtime = CLIBrainRuntime(
            backend: CodexExecRuntime(homeBaseDirectory: directory.appendingPathComponent("homes")))
        let summarizer = makeClient(
            provider: .codexCLI, executable: executable, directory: directory,
            runtime: runtime, prewarm: false,
            systemPrompt: "summarize", tools: [], toolChoice: .auto)

        do {
            _ = try await summarizer.respond(
                messages: [.system("summarize"), .user("older turns")],
                tools: [],
                toolChoice: .auto)
            Issue.record("expected a tool item event to abort the summary")
        } catch {
            #expect(error.localizedDescription.contains("disallowed item event"))
        }
        runtime.terminateNow()
    }

    /// The one-shot summary's `turn.completed` event carries the turn's token usage. Discarding it
    /// left every Codex compaction in the session audit with unavailable input, cache, and output
    /// values even though the transport had reported them. The request record must also name the
    /// transport, because `codex exec` spells its usage keys differently from the app-server's
    /// schema and the metrics reader has to know which one it is holding.
    @Test func codexExecSummaryRecordsItsTransportAndTokenUsage() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let traffic = RecordingTrafficAudit()
        let executable = try makeExecutable(
            in: directory,
            named: "fake-codex",
            script: codexScript(
                trace: directory.appendingPathComponent("trace"),
                threadResult: Self.ephemeralThreadResult,
                execReply: "condensed briefing",
                execUsage: #"{"input_tokens":17102,"cached_input_tokens":9984,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}"#))
        let runtime = CLIBrainRuntime(
            backend: CodexExecRuntime(homeBaseDirectory: directory.appendingPathComponent("homes")))
        let summarizer = makeClient(
            provider: .codexCLI, executable: executable, directory: directory,
            runtime: runtime, prewarm: false, traffic: traffic,
            systemPrompt: "summarize", tools: [], toolChoice: .auto)

        let summary = try await summarizer.respond(
            messages: [.system("summarize"), .user("older turns")],
            tools: [],
            toolChoice: .auto)
        #expect(summary.outputText == "condensed briefing")
        runtime.terminateNow()

        let event = try #require(traffic.recorded.first)
        let request = try #require(
            try JSONSerialization.jsonObject(with: event.request) as? [String: Any])
        #expect(request["runtime"] as? String == "one-shot-exec")
        let responseBody = try #require(event.response)
        let response = try #require(
            try JSONSerialization.jsonObject(with: responseBody) as? [String: Any])
        let usage = try #require(
            (response["runtime"] as? [String: Any])?["usage"] as? [String: Any])
        #expect(usage["input_tokens"] as? Int == 17102)
        #expect(usage["cached_input_tokens"] as? Int == 9984)
        #expect(usage["cache_write_input_tokens"] as? Int == 0)
        #expect(usage["output_tokens"] as? Int == 5)
    }

    /// The one-shot summarizer path is text-only by construction: an image is rejected before any
    /// process is spawned rather than silently dropped into the `codex exec` document.
    @Test func codexExecRuntimeRejectsImageInput() async throws {
        let conversation = try await openExecConversation()
        do {
            _ = try await conversation.respond(
                to: LocalAgentTurn(input: [.imageJPEG(base64: "QUJD")], timeout: 1),
                onRequestDispatched: {})
            Issue.record("expected the text-only guard to reject an image")
        } catch {
            #expect(error.localizedDescription.contains("text-only"))
        }
    }

    private func openExecConversation(
        runtime: CodexExecRuntime = CodexExecRuntime()
    ) async throws -> any LocalAgentConversation {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexExecRuntimeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        return try await runtime.openConversation(
            for: LocalAgentConversationConfiguration(
                provider: .codexCLI,
                executable: URL(fileURLWithPath: "/fake/bin/codex"),
                model: "",
                reasoningEffort: "low",
                workDirectory: workDir,
                instructions: "condense the session so far",
                timeout: 5),
            deadline: Date().addingTimeInterval(5))
    }

    @Test func cancellingClaudePreparationStopsTheInitializingProcess() async throws {
        try await assertCancellingPreparationStopsProcess(provider: .claudeCode)
    }

    @Test func cancellingCodexPreparationStopsTheInitializingProcess() async throws {
        try await assertCancellingPreparationStopsProcess(provider: .codexCLI)
    }

    @Test func cancellingCodexThreadPreparationStopsTheAppServer() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let trace = directory.appendingPathComponent("trace")
        let executable = try makeExecutable(
            in: directory,
            named: "blocked-codex-thread",
            script: """
                #!/bin/sh
                printf '%s\\n' "$$" > '\(shellQuoted(pidFile.path))'
                while IFS= read -r line; do
                  printf 'input: %s\\n' "$line" >> '\(shellQuoted(trace.path))'
                  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
                  method=$(printf '%s' "$line" | sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p' | tr -d '\\\\')
                  if [ "$method" = "initialize" ]; then
                    printf '{"id":%s,"result":{}}\\n' "$request_id"
                  fi
                done
                """)
        let runtime = makeRuntime(provider: .codexCLI, directory: directory)
        let client = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: false)
        let task = Task {
            try await client.makeConversation()
        }
        try await waitForRequestCount(1, method: "thread/start", in: trace)
        try await waitForFile(pidFile)
        let pid = try #require(
            pid_t(String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))

        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("expected cancelled Codex thread preparation")
            return
        }
        #expect(error is CancellationError)
        try await waitForProcessExit(pid)
        #expect(kill(pid, 0) == -1)
    }

    @Test func claudeInitializationSkipsMalformedOutput() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            named: "fake-claude",
            script: """
                #!/bin/sh
                while IFS= read -r line; do
                  case "$line" in
                    *'"type":"control_request"'*)
                      request_id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
                      printf 'not-json\\n'
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
        runtime.terminateNow()
    }

    @Test func codexInitializationSkipsMalformedOutput() async throws {
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
                      printf 'not-json\\n'
                      printf '{"id":%s,"result":{}}\\n' "$request_id"
                      ;;
                    thread/start)
                      printf '{"id":%s,"result":{"thread":{"id":"thread-1","ephemeral":true,"path":null},"instructionSources":[]}}\\n' "$request_id"
                      ;;
                    thread/unsubscribe)
                      printf '{"id":%s,"result":{}}\\n' "$request_id"
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

        let conversation = try await client.makeConversation()
        await conversation.finish()
        runtime.terminateNow()
    }

    @Test func codexPrewarmsAndLeasesTheFirstTargetThread() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = directory.appendingPathComponent("trace")
        let executable = try makeExecutable(
            in: directory,
            named: "fake-codex",
            script: codexScript(trace: trace, threadResult: Self.ephemeralThreadResult))
        let runtime = makeRuntime(provider: .codexCLI, directory: directory)
        let client = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: true)

        try await waitForRequestCount(1, method: "thread/start", in: trace)
        #expect(requests(method: "turn/start", in: trace).isEmpty)

        let first = try await client.makeConversation()
        #expect(requests(method: "thread/start", in: trace).count == 1)
        await first.finish()

        let second = try await client.makeConversation()
        #expect(requests(method: "thread/start", in: trace).count == 2)
        await second.finish()
        runtime.terminateNow()
    }

    @Test func codexReplacesAPrewarmedThreadForAnotherTargetConfiguration() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = directory.appendingPathComponent("trace")
        let executable = try makeExecutable(
            in: directory,
            named: "fake-codex",
            script: codexScript(trace: trace, threadResult: Self.ephemeralThreadResult))
        let runtime = makeRuntime(provider: .codexCLI, directory: directory)
        let firstTarget = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: true)
        _ = firstTarget
        let replacementTarget = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: false,
            systemPrompt: "replacement coach prompt")

        try await waitForRequestCount(1, method: "thread/start", in: trace)
        let replacement = try await replacementTarget.makeConversation()
        #expect(requests(method: "thread/start", in: trace).count == 2)
        #expect(requests(method: "thread/unsubscribe", in: trace).count == 1)
        await replacement.finish()
        runtime.terminateNow()
    }

    /// A prewarm resumed after an attempt has installed its own thread must leave that thread
    /// alone. It used to treat the attempt's thread as stale and replace it, the attempt then
    /// replaced the prewarm's, and so on, one thread/unsubscribe plus thread/start per round,
    /// until the attempt happened to be resumed first. The open runs at background priority and
    /// the prewarm at utility, so the prewarm wins every resume race: exactly the order that
    /// traded evictions.
    @Test func aPrewarmDoesNotReplaceTheThreadAnAttemptIsOpening() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = directory.appendingPathComponent("trace")
        let gate = directory.appendingPathComponent("thread-start-gate")
        let executable = try makeExecutable(
            in: directory,
            named: "fake-codex",
            script: codexScript(
                trace: trace,
                threadResult: Self.ephemeralThreadResult,
                threadStartGate: gate))
        let runtime = makeRuntime(provider: .codexCLI, directory: directory)
        let attempt = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: false,
            systemPrompt: "attempt coach prompt")
        let leased = directory.appendingPathComponent("leased")
        let opening = Task.detached(priority: .background) {
            let conversation = try await attempt.makeConversation()
            try Data().write(to: leased)
            return conversation
        }
        // The attempt's thread/start is in the trace, and the fake will not answer it until the
        // gate exists: the open is parked on its own preparation.
        try await waitForRequestCount(1, method: "thread/start", in: trace)

        let prewarming = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: true)
        _ = prewarming
        // Let the prewarm reach the parked preparation. Nothing observable marks that moment; a
        // prewarm that only arrives after the gate opens finds the leased thread and returns, so a
        // late one makes this case pass vacuously rather than fail.
        try await Task.sleep(nanoseconds: 300_000_000)
        try Data().write(to: gate)

        // Poll for the lease rather than awaiting the task: awaiting would escalate the open to
        // this task's priority and hand it the resume race the case exists to lose.
        try await waitForFile(leased)
        let conversation = try await opening.value
        #expect(requests(method: "thread/start", in: trace).count == 1)
        #expect(requests(method: "thread/unsubscribe", in: trace).isEmpty)
        await conversation.finish()
        runtime.terminateNow()
    }

    /// A newer prewarm for another configuration still replaces an idle prepared thread, so a
    /// route replacement or topology edit keeps its head start: the attempt that follows leases
    /// the replacement's thread instead of starting one.
    @Test func aNewerPrewarmReplacesAnIdleThreadPreparedForAnotherConfiguration() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = directory.appendingPathComponent("trace")
        let executable = try makeExecutable(
            in: directory,
            named: "fake-codex",
            script: codexScript(trace: trace, threadResult: Self.ephemeralThreadResult))
        let runtime = makeRuntime(provider: .codexCLI, directory: directory)
        let firstTarget = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: true)
        _ = firstTarget
        try await waitForRequestCount(1, method: "thread/start", in: trace)

        let replacementTarget = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: true,
            systemPrompt: "replacement coach prompt")
        try await waitForRequestCount(2, method: "thread/start", in: trace)

        let replacement = try await replacementTarget.makeConversation()
        #expect(requests(method: "thread/start", in: trace).count == 2)
        #expect(requests(method: "thread/unsubscribe", in: trace).count == 1)
        await replacement.finish()
        runtime.terminateNow()
    }

    @Test func releasingPreparedCodexRuntimeStopsItsSessionProcess() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let trace = directory.appendingPathComponent("trace")
        let executable = try makeExecutable(
            in: directory,
            named: "fake-codex",
            script: codexScript(
                pidFile: pidFile,
                trace: trace,
                threadResult: Self.ephemeralThreadResult))
        var runtime: CLIBrainRuntime? = makeRuntime(
            provider: .codexCLI,
            directory: directory)
        var client: CLIBrainClient? = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: try #require(runtime),
            prewarm: true)
        _ = client

        try await waitForRequestCount(1, method: "thread/start", in: trace)
        let pid = try #require(
            pid_t(String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))

        client = nil
        runtime = nil
        try await waitForProcessExit(pid)
        #expect(kill(pid, 0) == -1)
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

    /// Codex coaching is enabled at parity with the `codex exec` envelope it replaces, so both
    /// delivery surfaces — the app-server argv and the per-thread `thread/start` parameters — have
    /// to carry every isolation control. Feature disables ride both paths because `--disable <name>`
    /// is only documented as equivalent to `-c features.<name>=false`, and openai/codex#21952
    /// reports the launch flag not reaching the app-server's tool builder.
    @Test func codexLaunchAndThreadStartCarryTheIsolationEnvelope() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let argumentsFile = directory.appendingPathComponent("arguments")
        let trace = directory.appendingPathComponent("trace")
        let executable = try makeExecutable(
            in: directory,
            named: "fake-codex",
            script: codexScript(
                argumentsFile: argumentsFile,
                trace: trace,
                threadResult: Self.ephemeralThreadResult))
        let runtime = CLIBrainRuntime(
            provider: .codexCLI,
            codexRuntimeBaseDirectory: directory.appendingPathComponent("agent-runtimes"),
            // "unified_exec" is advertised; "goals" is not, and must never be passed.
            codexSupportedFeatures: ["shell_tool", "unified_exec", "browser_use"])
        let client = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: false)

        _ = try await client.respond(
            messages: [.system("coach prompt"), .user("help")],
            tools: coachTools,
            toolChoice: .required)
        runtime.terminateNow()

        let arguments = try readArguments(argumentsFile)
        #expect(arguments.contains("app-server"))
        #expect(arguments.contains("--stdio"))
        #expect(containsPair("-c", "mcp_servers={}", in: arguments))
        #expect(containsPair("-c", "project_root_markers=[]", in: arguments))
        #expect(containsPair("-c", "project_doc_max_bytes=0", in: arguments))
        for feature in ["shell_tool", "unified_exec", "browser_use"] {
            #expect(containsPair("--disable", feature, in: arguments))
        }
        #expect(!arguments.contains("goals"))
        // Nothing may relax the envelope the way an approval or write flag would.
        #expect(!arguments.contains { $0.hasPrefix("--dangerously") })

        let start = try #require(request(method: "thread/start", in: trace))
        #expect(start["approvalPolicy"] as? String == "never")
        #expect(start["sandbox"] as? String == "read-only")
        #expect(start["ephemeral"] as? Bool == true)
        #expect((start["baseInstructions"] as? String)?
            .hasPrefix(JarvisPrompts.LocalAgent.codexDirectResponse) == true)
        let config = try #require(start["config"] as? [String: Any])
        #expect((config["mcp_servers"] as? [String: Any])?.isEmpty == true)
        #expect((config["project_root_markers"] as? [Any])?.isEmpty == true)
        #expect(config["project_doc_max_bytes"] as? Int == 0)
        let features = try #require(config["features"] as? [String: Bool])
        #expect(features == ["shell_tool": false, "unified_exec": false, "browser_use": false])
    }

    @Test func codexRejectsANonEphemeralThread() async throws {
        try await assertCodexRejectsThread(
            result: """
                {"thread":{"id":"thread-1","ephemeral":false,"path":"/tmp/rollout.jsonl"},"instructionSources":[]}
                """)
    }

    @Test func codexRejectsAnInstructionLoadedThread() async throws {
        try await assertCodexRejectsThread(
            result: """
                {"thread":{"id":"thread-1","ephemeral":true,"path":null},"instructionSources":["/Users/someone/AGENTS.md"]}
                """)
    }

    /// Compaction must never contend with coaching. Codex's app-server admits one conversation at a
    /// time, so while the two shared a runtime an off-path summary made the *next* coaching attempt
    /// fail to open — and three counted failures exhaust the target and advance the route. The
    /// summarizer now spawns a one-shot `codex exec`, so it runs while a coaching conversation is
    /// still open and the app-server never sees a second thread.
    @Test func codexCompactionRunsWithoutTouchingTheCoachAppServer() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = directory.appendingPathComponent("trace")
        let executable = try makeExecutable(
            in: directory,
            named: "fake-codex",
            script: codexScript(
                trace: trace,
                threadResult: Self.ephemeralThreadResult,
                execReply: "condensed briefing"))
        let runtime = CLIBrainRuntime(
            provider: .codexCLI,
            codexRuntimeBaseDirectory: directory.appendingPathComponent("agent-runtimes"))
        let runtimes = LocalAgentRuntimeSet(provider: .codexCLI, sharedCoach: runtime)
        #expect(runtimes.coach !== runtimes.summarizer)
        let coach = makeClient(
            provider: .codexCLI, executable: executable, directory: directory,
            runtime: runtimes.coach, prewarm: false)
        let summarizer = makeClient(
            provider: .codexCLI, executable: executable, directory: directory,
            runtime: runtimes.summarizer, prewarm: false,
            systemPrompt: "summarize", tools: [], toolChoice: .auto)

        // Hold the coaching conversation open across the summary. Under the shared runtime this is
        // exactly the collision that failed a coaching attempt.
        let conversation = try await coach.makeConversation()
        _ = try await conversation.respond(
            messages: [.system("coach prompt"), .user("help")],
            tools: coachTools,
            toolChoice: .required)

        let summary = try await summarizer.respond(
            messages: [.system("summarize"), .user("older turns")],
            tools: [],
            toolChoice: .auto)
        #expect(summary.outputText == "condensed briefing")

        await conversation.finish()
        runtime.terminateNow()
        runtimes.summarizer.terminateNow()

        // One app-server, one thread: compaction never opened one.
        #expect(requests(method: "thread/start", in: trace).count == 1)
        #expect(requests(method: "initialize", in: trace).count == 1)
    }

    @Test func timedOutCodexCompactionInterruptsOnlyItsThread() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = directory.appendingPathComponent("trace")
        let executable = try makeExecutable(
            in: directory,
            named: "fake-codex",
            script: """
                #!/bin/sh
                thread_number=0
                while IFS= read -r line; do
                  printf 'input: %s\\n' "$line" >> '\(shellQuoted(trace.path))'
                  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
                  method=$(printf '%s' "$line" | sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p' | tr -d '\\\\')
                  case "$method" in
                    initialize)
                      printf '{"id":%s,"result":{}}\\n' "$request_id"
                      ;;
                    thread/start)
                      thread_number=$((thread_number + 1))
                      active_thread="thread-$thread_number"
                      printf '{"id":%s,"result":{"thread":{"id":"%s","ephemeral":true,"path":null},"instructionSources":[]}}\\n' "$request_id" "$active_thread"
                      ;;
                    thread/unsubscribe)
                      printf '{"id":%s,"result":{}}\\n' "$request_id"
                      ;;
                    turn/start)
                      active_thread=$(printf '%s' "$line" | sed -n 's/.*"threadId":"\\([^"]*\\)".*/\\1/p')
                      turn_number=${active_thread#thread-}
                      active_turn="turn-$turn_number"
                      printf '{"id":%s,"result":{"turn":{"id":"%s","status":"inProgress","items":[]}}}\\n' "$request_id" "$active_turn"
                      if [ "$active_thread" != "thread-2" ]; then
                        printf '{"method":"item/completed","params":{"threadId":"%s","turnId":"%s","item":{"type":"agentMessage","text":"%s"}}}\\n' "$active_thread" "$active_turn" '{\\"tool\\":\\"stay_silent\\",\\"arguments\\":{}}'
                        printf '{"method":"turn/completed","params":{"threadId":"%s","turn":{"id":"%s","status":"completed","items":[{"type":"agentMessage"}]}}}\\n' "$active_thread" "$active_turn"
                      fi
                      ;;
                    turn/interrupt)
                      interrupted_thread=$(printf '%s' "$line" | sed -n 's/.*"threadId":"\\([^"]*\\)".*/\\1/p')
                      interrupted_turn=$(printf '%s' "$line" | sed -n 's/.*"turnId":"\\([^"]*\\)".*/\\1/p')
                      printf '{"id":%s,"result":{}}\\n' "$request_id"
                      printf '{"method":"turn/completed","params":{"threadId":"%s","turn":{"id":"%s","status":"interrupted","items":[]}}}\\n' "$interrupted_thread" "$interrupted_turn"
                      ;;
                  esac
                done
                """)
        let runtime = makeRuntime(provider: .codexCLI, directory: directory)
        let coach = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: false,
            timeout: 2)
        let summarizer = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: false,
            systemPrompt: "summarize",
            tools: [],
            toolChoice: .auto,
            timeout: 0.2)

        let firstConversation = try await coach.makeConversation()
        _ = try await firstConversation.respond(
            messages: [.system("coach prompt"), .user("first")],
            tools: coachTools,
            toolChoice: .required)
        await firstConversation.finish()

        do {
            _ = try await summarizer.respond(
                messages: [.system("summarize"), .user("older turns")],
                tools: [],
                toolChoice: .auto)
            Issue.record("expected compaction to time out")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
        }

        let nextConversation = try await coach.makeConversation()
        let nextResponse = try await nextConversation.respond(
            messages: [.system("coach prompt"), .user("newer speech")],
            tools: coachTools,
            toolChoice: .required)
        await nextConversation.finish()
        guard case .staySilent = try #require(nextResponse.toolCalls.first) else {
            Issue.record("expected the next coaching turn to use the shared server")
            return
        }
        runtime.terminateNow()

        #expect(requests(method: "initialize", in: trace).count == 1)
        #expect(requests(method: "thread/start", in: trace).count == 3)
        let interrupt = try #require(request(method: "turn/interrupt", in: trace))
        #expect(interrupt["threadId"] as? String == "thread-2")
        #expect(interrupt["turnId"] as? String == "turn-2")
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
        prewarm: Bool,
        traffic: (any BrainTrafficAuditing)? = nil,
        systemPrompt: String = "coach prompt",
        tools: [ToolDef] = coachTools,
        toolChoice: ToolChoice = .required,
        timeout: TimeInterval = 10
    ) -> CLIBrainClient {
        CLIBrainClient(
            provider: provider,
            executable: executable,
            model: "",
            workDirectory: directory,
            timeout: timeout,
            traffic: traffic,
            systemPrompt: systemPrompt,
            tools: tools,
            toolChoice: toolChoice,
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
        CLIBrainRuntime(
            provider: provider,
            codexRuntimeBaseDirectory: directory.appendingPathComponent("agent-runtimes"))
    }

    private static let ephemeralThreadResult =
        #"{"thread":{"id":"thread-1","ephemeral":true,"path":null},"instructionSources":[]}"#

    /// A fake `codex app-server` that records its argv and every request it is sent, then answers
    /// with a single `stay_silent` agent message. With `threadStartGate` set, no `thread/start` is
    /// answered until that file exists, which parks whoever is preparing a thread.
    private func codexScript(
        argumentsFile: URL? = nil,
        pidFile: URL? = nil,
        trace: URL,
        threadResult: String,
        threadStartGate: URL? = nil,
        execReply: String? = nil,
        execItemType: String = "agent_message",
        execUsage: String = "{}"
    ) -> String {
        let recordArguments = argumentsFile.map {
            "printf 'arg=<%s>\\n' \"$@\" > '\(shellQuoted($0.path))'\n"
        } ?? ""
        let recordPID = pidFile.map {
            "printf '%s\\n' \"$$\" > '\(shellQuoted($0.path))'\n"
        } ?? ""
        let threadStartGateWait = threadStartGate.map {
            "while [ ! -e '\(shellQuoted($0.path))' ]; do sleep 0.01; done"
        } ?? ""
        // `codex exec --json` is a different program shape from the app-server: one shot, JSONL
        // events on stdout, and the reply written to the --output-last-message path.
        let execBranch = execReply.map { reply in
            """
            if [ "$1" = "exec" ]; then
              printf 'input: exec\\n' >> '\(shellQuoted(trace.path))'
              cat > /dev/null
              printf '{"type":"thread.started","thread_id":"t1"}\\n'
              printf '{"type":"turn.started"}\\n'
              printf '{"type":"item.completed","item":{"id":"i1","type":"\(execItemType)","text":"\(shellQuoted(reply))"}}\\n'
              printf '{"type":"turn.completed","usage":%s}\\n' '\(execUsage)'
              exit 0
            fi

            """
        } ?? ""
        return """
            #!/bin/sh
            \(execBranch)\(recordPID)\(recordArguments)while IFS= read -r line; do
              printf 'input: %s\\n' "$line" >> '\(shellQuoted(trace.path))'
              request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
              method=$(printf '%s' "$line" | sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p' | tr -d '\\\\')
              case "$method" in
                initialize)
                  printf '{"id":%s,"result":{}}\\n' "$request_id"
                  ;;
                thread/start)
                  \(threadStartGateWait)
                  printf '{"id":%s,"result":%s}\\n' "$request_id" '\(shellQuoted(threadResult))'
                  ;;
                thread/unsubscribe)
                  printf '{"id":%s,"result":{}}\\n' "$request_id"
                  ;;
                turn/start)
                  printf '%s\\n' '{"method":"item/completed","params":{"threadId":"thread-1","item":{"type":"agentMessage","text":"{\\"tool\\":\\"stay_silent\\",\\"arguments\\":{}}"}}}'
                  printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"status":"completed","items":[{"type":"agentMessage"}]}}}'
                  ;;
              esac
            done
            """
    }

    private func assertCodexRejectsThread(result: String) async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = directory.appendingPathComponent("trace")
        let executable = try makeExecutable(
            in: directory,
            named: "fake-codex",
            script: codexScript(trace: trace, threadResult: result))
        let runtime = makeRuntime(provider: .codexCLI, directory: directory)
        let client = makeClient(
            provider: .codexCLI,
            executable: executable,
            directory: directory,
            runtime: runtime,
            prewarm: false)
        do {
            _ = try await client.makeConversation()
            Issue.record("expected a rejected thread")
        } catch {
            #expect(error.localizedDescription
                .contains("non-ephemeral or instruction-loaded thread"))
        }
        runtime.terminateNow()
    }

    private func readArguments(_ file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .map { String($0.dropFirst("arg=<".count).dropLast()) }
    }

    /// The `params` of every recorded request with the given method, in order.
    private func requests(method: String, in trace: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: trace, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard line.hasPrefix("input: ") else { return nil }
            let json = Data(line.dropFirst("input: ".count).utf8)
            guard let payload = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  payload["method"] as? String == method else {
                return nil
            }
            return payload["params"] as? [String: Any] ?? [:]
        }
    }

    private func request(method: String, in trace: URL) -> [String: Any]? {
        requests(method: method, in: trace).first
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
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try #require(
            FileManager.default.fileExists(atPath: file.path),
            "timed out waiting for \(file.lastPathComponent)")
    }

    private func waitForLineCount(_ expected: Int, in file: URL) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               text.split(separator: "\n").count >= expected {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let count = (try? String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").count) ?? 0
        _ = try #require(count >= expected, "timed out waiting for \(expected) launches")
    }

    private func waitForRequestCount(
        _ expected: Int,
        method: String,
        in trace: URL
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if requests(method: method, in: trace).count >= expected {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try #require(
            requests(method: method, in: trace).count >= expected,
            "timed out waiting for \(expected) \(method) requests")
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

/// Captures the exact bytes the client hands the audit port, synchronously on the calling thread.
///
/// This suite is serialized and every test in it spawns real subprocesses that hold GCD threads, so
/// a file-backed `FileSessionAudit` would add a background worker queue plus two waits with no
/// deadline — its readiness spin and its close — either of which hangs the whole suite forever if
/// that queue is slow to be scheduled. The record's JSONL round-trip is covered by
/// `FileSessionAuditTrafficTests`; what matters here is what `CLIBrainClient` emits.
///
/// `@unchecked Sendable` is justified because `lock` guards the only mutable state.
private final class RecordingTrafficAudit: BrainTrafficAuditing, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BrainTrafficAuditEvent] = []

    var recorded: [BrainTrafficAuditEvent] {
        lock.withLock { events }
    }

    func record(_ event: BrainTrafficAuditEvent) {
        lock.withLock { events.append(event) }
    }
}
