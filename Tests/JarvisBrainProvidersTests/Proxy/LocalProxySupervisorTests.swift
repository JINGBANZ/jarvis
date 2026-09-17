import Foundation
import JarvisBrainProviders
import JarvisCore
import Testing

/// The test serves the model list itself, so a stub script may still be starting when the
/// supervisor reports it running.
@Suite struct LocalProxySupervisorTests {
    private static let openAIModels = #"{"data":[{"id":"gpt-5.6-sol","owned_by":"openai"}]}"#

    private func configuredPort(_ supervisor: LocalProxySupervisor) async throws -> Int {
        let config = supervisor.configURL
        #expect(await eventually { FileManager.default.fileExists(atPath: config.path) })
        let text = try String(contentsOf: config, encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("port: ") })
        return try #require(Int(line.dropFirst("port: ".count)))
    }

    /// Records errors instead of rethrowing so the stub helper is always stopped.
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
            // Without it the helper logs failed-call bodies (transcript, screen text) to its own
            // directory.
            #expect(config.contains("commercial-mode: true"))
            // Privacy settings a helper version bump must not silently re-enable.
            #expect(config.contains("usage-statistics-enabled: false"))
            #expect(config.contains("allow-remote: false"))
            #expect(config.contains("error-logs-max-files: 2"))
            let manager = FileManager.default
            #expect(try manager.attributesOfItem(atPath: supervisor.configURL.path)[.posixPermissions]
                as? Int == 0o600)
            #expect(try manager.attributesOfItem(atPath: supervisor.authDirectory.path)[.posixPermissions]
                as? Int == 0o700)
            #expect(await contents(of: home.appendingPathComponent("arguments"))
                == "-config\n\(supervisor.configURL.path)\n-local-model\n")
        }
    }

    /// Dumps written without `commercial-mode` hold transcript and screen text in a world-readable
    /// directory.
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

    /// The supervisor gives up at the fourth stop within its window. Each helper exits only once the
    /// test has seen it answer: a helper that exits mid-probe leaves the start unfinished with no
    /// restart, so a fixed lifetime flakes on a slow runner.
    @Test func aHelperThatKeepsStoppingRestartsThenGivesUp() async throws {
        try await withSupervisor(
            script: """
                dir="$(dirname "$0")"
                echo launched >> "$dir/launches"
                life=$(grep -c . "$dir/launches")
                until [ -e "$dir/release-$life" ]; do sleep 0.05; done
                """,
            clock: ImmediateClock()
        ) { supervisor, first, home async throws in
            guard case .running(let endpoint) = first else {
                Issue.record("expected the first start to answer, got \(first)")
                return
            }
            let launches = home.appendingPathComponent("launches")
            @Sendable func launchCount() -> Int {
                ((try? String(contentsOf: launches, encoding: .utf8)) ?? "").split(separator: "\n").count
            }
            for life in 1...4 {
                // Count first: once this launch is recorded, `.running` can only be its own.
                #expect(await eventually {
                    guard launchCount() == life else { return false }
                    return await supervisor.state == .running(endpoint)
                })
                FileManager.default.createFile(
                    atPath: home.appendingPathComponent("release-\(life)").path, contents: nil)
            }
            #expect(await eventually { await supervisor.state == .failed(reason: "keeps stopping") })
            #expect(launchCount() == 4)
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

    @Test func terminateNowEndsEveryRunningSignIn() async throws {
        try await withSupervisor(script: """
            case "$1" in
            -codex-login|-claude-login)
                echo $$ > "$(dirname "$0")/login$1.partial"
                mv "$(dirname "$0")/login$1.partial" "$(dirname "$0")/login$1"
                exec /bin/sleep 600
                ;;
            esac
            exec /bin/sleep 600
            """) { supervisor, state, home in
            guard case .running = state else {
                Issue.record("expected the helper to be running, got \(state)")
                return
            }
            let signIn = try #require(await supervisor.makeSignIn())
            let codex = Task { for await _ in signIn.run(.codexSubscription) {} }
            let claude = Task { for await _ in signIn.run(.claudeSubscription) {} }
            defer {
                codex.cancel()
                claude.cancel()
            }
            var running: [Int32] = []
            for name in ["login-codex-login", "login-claude-login"] {
                let text = await contents(of: home.appendingPathComponent(name)) ?? ""
                running.append(try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))))
            }
            let logins = running
            #expect(logins.count == 2)

            supervisor.terminateNow()

            #expect(await eventually { logins.allSatisfy { !processExists($0) } })
        }
    }

    @Test func aSilentHelperIsReplacedOnTheSameEndpoint() async throws {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let supervisor = LocalProxySupervisor(
            executable: try proxyStubExecutable(in: home, script: """
                echo $$ > "$(dirname "$0")/pid.partial"
                mv "$(dirname "$0")/pid.partial" "$(dirname "$0")/pid"
                exec /bin/sleep 600
                """),
            home: home, clock: ImmediateClock())
        let starting = Task { await supervisor.ensureRunning() }
        let port = try await configuredPort(supervisor)
        var stub: ModelListStub? = try ModelListStub(port: port, body: Self.openAIModels)
        guard case .running(let endpoint) = await starting.value else {
            Issue.record("expected the helper to answer its first probe")
            return
        }
        let text = await contents(of: home.appendingPathComponent("pid")) ?? ""
        let silentPID = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))

        stub?.stop()
        let silent = await supervisor.readiness()
        guard case .unavailable(let reason) = silent else {
            Issue.record("expected a silent helper to be unavailable, got \(silent)")
            return
        }
        #expect(reason == "stopped answering")
        #expect(await eventually { !processExists(silentPID) })

        stub = try ModelListStub(port: port, body: Self.openAIModels)
        let recovered = await supervisor.readiness()
        guard case .ready(let replacement, _) = recovered else {
            Issue.record("expected a replacement helper, got \(recovered)")
            return
        }
        #expect(replacement.baseURL == endpoint.baseURL)
        #expect(replacement.key == endpoint.key)
        await supervisor.stop()
        stub?.stop()
    }

    /// The third-party helper reads database, object-store and proxy variables that could move a
    /// credential off this Mac or reroute pinned traffic.
    @Test func theHelperInheritsOnlyTheAllowlistedEnvironment() async throws {
        setenv("JARVIS_PROXY_ENV_PROBE", "leaked", 1)
        defer { unsetenv("JARVIS_PROXY_ENV_PROBE") }
        try await withSupervisor(script: """
            /usr/bin/env > "$(dirname "$0")/environment.partial"
            mv "$(dirname "$0")/environment.partial" "$(dirname "$0")/environment"
            exec /bin/sleep 600
            """) { supervisor, state, home in
            guard case .running = state else {
                Issue.record("expected the helper to be running, got \(state)")
                return
            }
            let dump = await contents(of: home.appendingPathComponent("environment")) ?? ""
            let names = Set(dump.split(separator: "\n").compactMap {
                $0.split(separator: "=").first.map(String.init)
            })
            #expect(!names.contains("JARVIS_PROXY_ENV_PROBE"))
            #expect(names.contains("PATH"))
            #expect(names.contains("HOME"))
        }
    }

    @Test func aCancelledProbeLeavesTheHelperRunning() async throws {
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

            let probe = Task { await supervisor.readiness() }
            probe.cancel()
            _ = await probe.value

            #expect(processExists(pid))
            let after = await supervisor.state
            guard case .running = after else {
                Issue.record("expected the helper to stay running, got \(after)")
                return
            }
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
