import Foundation
import JarvisBrainProviders
import JarvisCore
import Testing

/// The supervisor against stub helpers: shell scripts that stay up or exit, with the model list
/// served by the test on the port the supervisor wrote into its configuration. The test serves that
/// list itself, so a stub script may still be starting when the supervisor reports it running.
@Suite struct LocalProxySupervisorTests {
    private static let openAIModels = #"{"data":[{"id":"gpt-5.6-sol","owned_by":"openai"}]}"#

    /// The port from this launch's configuration, once the supervisor has written it.
    private func configuredPort(_ supervisor: LocalProxySupervisor) async throws -> Int {
        let config = supervisor.configURL
        #expect(await eventually { FileManager.default.fileExists(atPath: config.path) })
        let text = try String(contentsOf: config, encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("port: ") })
        return try #require(Int(line.dropFirst("port: ".count)))
    }

    /// Runs `body` against a supervisor whose helper is `script`, serving `models` on its port, and
    /// always stops the helper afterwards so a failed expectation never leaves a stub running.
    private func withSupervisor(
        script: String,
        clock: any _Concurrency.Clock<Swift.Duration> = ContinuousClock(),
        models: String = openAIModels,
        _ body: (LocalProxySupervisor, LocalProxySupervisor.State, URL) async throws -> Void
    ) async throws {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let supervisor = LocalProxySupervisor(
            executable: try proxyStubExecutable(in: home, script: script), home: home, clock: clock)
        let starting = Task { await supervisor.ensureRunning() }
        var stub: ModelListStub?
        do {
            stub = try ModelListStub(port: try await configuredPort(supervisor), body: models)
            try await body(supervisor, await starting.value, home)
        } catch {
            Issue.record(error)
        }
        await supervisor.stop()
        stub?.stop()
    }

    private func contents(of url: URL) async -> String? {
        _ = await eventually { FileManager.default.fileExists(atPath: url.path) }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    @Test func startsTheHelperWithAnOwnerOnlyConfiguration() async throws {
        try await withSupervisor(script: """
            printf '%s\\n' "$@" > "$(dirname "$0")/arguments.partial"
            mv "$(dirname "$0")/arguments.partial" "$(dirname "$0")/arguments"
            exec /bin/sleep 600
            """) { supervisor, state, home in
            guard case .running(let endpoint) = state else {
                Issue.record("expected the helper to be running, got \(state)")
                return
            }
            let port = try await configuredPort(supervisor)
            #expect(endpoint.baseURL.absoluteString == "http://127.0.0.1:\(port)")
            #expect(endpoint.key.count == 32)

            let config = try String(contentsOf: supervisor.configURL, encoding: .utf8)
            #expect(config.contains("  - \"\(endpoint.key)\""))
            #expect(config.contains("auth-dir: \"\(supervisor.authDirectory.path)\""))
            #expect(config.contains("disable-image-generation: true"))
            #expect(config.contains("disable-control-panel: true"))
            // Without this the helper writes a failed call's body, transcript and screen text
            // included, to its own logs directory, outside the session that owns that data.
            #expect(config.contains("commercial-mode: true"))
            let manager = FileManager.default
            #expect(try manager.attributesOfItem(atPath: supervisor.configURL.path)[.posixPermissions]
                as? Int == 0o600)
            #expect(try manager.attributesOfItem(atPath: supervisor.authDirectory.path)[.posixPermissions]
                as? Int == 0o700)
            #expect(await contents(of: home.appendingPathComponent("arguments"))
                == "-config\n\(supervisor.configURL.path)\n-local-model\n")
        }
    }

    /// A build before `commercial-mode` let the helper dump a failed call's body, transcript and
    /// captured screen text included, into its own world-readable logs directory. Upgrading clears
    /// what that build wrote and narrows the directory; the helper's own log survives.
    @Test func startPrunesAndNarrowsTheHelperLogDirectory() async throws {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = FileManager.default
        let logs = home.appendingPathComponent("auth/logs", isDirectory: true)
        try manager.createDirectory(at: logs, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o755])
        let dump = logs.appendingPathComponent("error-v1-responses-old.log")
        try Data("Captured screen text evidence".utf8).write(to: dump)
        let spool = logs.appendingPathComponent("request-body-old.tmp")
        try Data("New since last turn".utf8).write(to: spool)
        let ownLog = logs.appendingPathComponent("main.log")
        try Data("started".utf8).write(to: ownLog)

        let supervisor = LocalProxySupervisor(
            executable: try proxyStubExecutable(in: home, script: "exec /bin/sleep 600"),
            home: home, clock: ContinuousClock())
        let starting = Task { await supervisor.ensureRunning() }
        let stub = try ModelListStub(
            port: try await configuredPort(supervisor), body: Self.openAIModels)
        _ = await starting.value

        #expect(!manager.fileExists(atPath: dump.path))
        #expect(!manager.fileExists(atPath: spool.path))
        #expect(manager.fileExists(atPath: ownLog.path))
        #expect(try manager.attributesOfItem(atPath: logs.path)[.posixPermissions] as? Int == 0o700)
        await supervisor.stop()
        stub.stop()
    }

    @Test func readinessNamesTheSubscriptionsTheHelperServes() async throws {
        try await withSupervisor(script: "exec /bin/sleep 600") { supervisor, _, _ in
            let readiness = await supervisor.readiness()
            guard case .ready(_, let signedIn) = readiness else {
                Issue.record("expected a ready helper, got \(readiness)")
                return
            }
            #expect(signedIn == [.codexSubscription])
            #expect(readiness.unavailability(for: .codexSubscription) == nil)
            let signedOut = try #require(readiness.unavailability(for: .claudeSubscription))
            #expect(signedOut.category == .authentication)
            #expect(signedOut.disposition == .permanent)
            #expect(signedOut.source == .brain(.claudeSubscription))
        }
    }

    @Test func aHelperThatExitsBeforeAnsweringFailsTheStart() async throws {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let supervisor = LocalProxySupervisor(
            executable: try proxyStubExecutable(in: home, script: "exit 3"), home: home)

        #expect(await supervisor.ensureRunning() == .failed(reason: "stopped with status 3 while starting"))
        let unavailable = await supervisor.readiness().unavailability(for: .claudeSubscription)
        #expect(unavailable?.category == .unavailable)
        #expect(unavailable?.stage == .process)
        #expect(unavailable?.message.hasPrefix("the sign-in service ") == true)
    }

    @Test func aBuildWithoutTheHelperFailsWithoutLaunching() async {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let supervisor = LocalProxySupervisor(executable: nil, home: home)
        #expect(await supervisor.ensureRunning() == .failed(reason: "is missing from this build"))
    }

    /// A helper that stops after it answered restarts on the same port with the same key, until a
    /// fourth stop within the window gives up.
    @Test func aHelperThatKeepsStoppingRestartsThenGivesUp() async throws {
        try await withSupervisor(
            script: "echo launched >> \"$(dirname \"$0\")/launches\"\nexec /bin/sleep 0.4",
            clock: ImmediateClock()
        ) { supervisor, first, home in
            guard case .running(let endpoint) = first else {
                Issue.record("expected the first start to answer, got \(first)")
                return
            }
            #expect(await eventually { await supervisor.state == .failed(reason: "keeps stopping") })
            let launches = try String(contentsOf: home.appendingPathComponent("launches"), encoding: .utf8)
            #expect(launches.split(separator: "\n").count == 4)
            #expect(try await configuredPort(supervisor) == endpoint.baseURL.port)
            #expect(try String(contentsOf: supervisor.configURL, encoding: .utf8)
                .contains("  - \"\(endpoint.key)\""))
        }
    }

    @Test func stopTerminatesTheHelper() async throws {
        try await withSupervisor(script: """
            echo $$ > "$(dirname "$0")/pid.partial"
            mv "$(dirname "$0")/pid.partial" "$(dirname "$0")/pid"
            exec /bin/sleep 600
            """) { supervisor, state, home in
            guard case .running = state else {
                Issue.record("expected the helper to be running, got \(state)")
                return
            }
            let text = await contents(of: home.appendingPathComponent("pid")) ?? ""
            let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(processExists(pid))

            await supervisor.stop()

            #expect(await supervisor.state == .stopped)
            #expect(await eventually { !processExists(pid) })
            #expect(!FileManager.default.fileExists(atPath: supervisor.configURL.path))
        }
    }

    @Test func signOutRemovesOnlyThatSubscriptionsCredentials() throws {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let supervisor = LocalProxySupervisor(executable: nil, home: home)
        try FileManager.default.createDirectory(at: supervisor.authDirectory, withIntermediateDirectories: true)
        for name in ["claude-1-a@example.com.json", "codex-2-a@example.com-plus.json"] {
            FileManager.default.createFile(
                atPath: supervisor.authDirectory.appendingPathComponent(name).path, contents: Data("{}".utf8))
        }

        try supervisor.signOut(.claudeSubscription)

        #expect(supervisor.accountFiles(for: .claudeSubscription).isEmpty)
        #expect(supervisor.accountFiles(for: .codexSubscription).count == 1)
    }
}
