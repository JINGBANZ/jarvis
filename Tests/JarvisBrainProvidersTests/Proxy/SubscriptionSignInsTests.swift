import Foundation
import JarvisBrainProviders
import JarvisCore
import Testing
import os

@MainActor
@Suite struct SubscriptionSignInsTests {
    private nonisolated static let models = #"{"data":[{"id":"gpt-6.1-sol","owned_by":"openai"}]}"#
    private nonisolated static let expired = #"{"files":[{"name":"codex-fixture.json","auth_index":"one","provider":"codex","status":"error","disabled":false,"unavailable":true,"status_message":"token expired","cooldowns":[]}]}"#
    private nonisolated static let active = #"{"files":[{"name":"codex-fixture.json","auth_index":"one","provider":"codex","status":"active","disabled":false,"unavailable":false,"status_message":"","cooldowns":[]}]}"#
    private nonisolated static let rejected = #"{"files":[{"name":"codex-fixture.json","auth_index":"one","provider":"codex","status":"error","disabled":false,"unavailable":true,"status_message":"unauthorized","cooldowns":[]}]}"#

    private func withSignIns(
        respond: @escaping @Sendable (String) -> (Int, String),
        _ body: (SubscriptionSignIns, LocalProxySupervisor) async throws -> Void
    ) async throws {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let supervisor = LocalProxySupervisor(
            executable: try proxyStubExecutable(in: home, script: "idle"), home: home)
        let starting = Task { await supervisor.ensureRunning() }
        var stub: ModelListStub?
        do {
            let config = supervisor.configURL
            #expect(await eventually { FileManager.default.fileExists(atPath: config.path) })
            let text = try String(contentsOf: config, encoding: .utf8)
            let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("port: ") })
            let port = try #require(Int(line.dropFirst("port: ".count)))
            stub = try ModelListStub(port: port, respond: respond)
            _ = await starting.value
            try Data("{}".utf8).write(to: supervisor.authDirectory.appendingPathComponent("codex-fixture.json"))
            try await body(SubscriptionSignIns(supervisor: supervisor), supervisor)
        } catch {
            Issue.record(error)
        }
        await supervisor.stop()
        stub?.stop()
    }

    @Test func anExplicitRetryReplacesAPassiveCheckAndIgnoresItsLateAnswer() async throws {
        let calls = OSAllocatedUnfairLock(initialState: (health: 0, posts: 0))
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        try await withSignIns(respond: { request in
            if request.hasPrefix("POST ") {
                calls.withLock { $0.posts += 1 }
                return (200, "{}")
            }
            if request.contains("/v8/management/credentials") {
                let counts = calls.withLock { state in
                    state.health += 1
                    return state
                }
                if counts.health == 2 {
                    _ = release.wait(timeout: .now() + 5)
                    return (200, Self.rejected)
                }
                return (200, counts.posts > 0 ? Self.active : Self.expired)
            }
            return (200, Self.models)
        }) { signIns, supervisor in
            let previous = await supervisor.readiness()
            signIns.record(previous)
            var observedFailures: [ProviderFailure.Category] = []
            let observer = signIns.observe {
                if let failure = signIns.readiness?.unavailability(for: .codexSubscription) {
                    observedFailures.append(failure.category)
                }
            }
            defer { signIns.removeObserver(observer) }
            signIns.refresh()
            #expect(await eventually { calls.withLock { $0.health == 2 } })

            signIns.retry(.codexSubscription)

            #expect(signIns.retrying == .codexSubscription)
            #expect(signIns.readiness == previous)
            release.signal()
            #expect(await eventually {
                let retrying = await signIns.retrying
                let readiness = await signIns.readiness
                return retrying == nil && readiness?.signedIn == [.codexSubscription]
            })
            #expect(calls.withLock { $0.posts } == 1)
            #expect(!observedFailures.contains(.authentication))
        }
    }

    @Test func passiveRefreshAndOtherSnapshotsCannotInterruptAnActiveRetry() async throws {
        let calls = OSAllocatedUnfairLock(initialState: (posts: 0, refreshed: false))
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        try await withSignIns(respond: { request in
            if request.hasPrefix("POST ") {
                calls.withLock { $0.posts += 1 }
                _ = release.wait(timeout: .now() + 5)
                calls.withLock { $0.refreshed = true }
                return (200, "{}")
            }
            if request.contains("/v8/management/credentials") {
                return (200, calls.withLock { $0.refreshed } ? Self.active : Self.expired)
            }
            return (200, Self.models)
        }) { signIns, supervisor in
            let previous = await supervisor.readiness()
            signIns.record(previous)
            signIns.retry(.codexSubscription)
            #expect(await eventually { calls.withLock { $0.posts == 1 } })

            signIns.retry(.codexSubscription)
            signIns.retry(.claudeSubscription)
            signIns.refresh(replacingPending: true, checkingEmptyAccounts: true)
            signIns.record(.unavailable(reason: "an older check failed"))

            #expect(signIns.retrying == .codexSubscription)
            #expect(signIns.readiness == previous)
            release.signal()
            #expect(await eventually {
                let retrying = await signIns.retrying
                let readiness = await signIns.readiness
                return retrying == nil && readiness?.signedIn == [.codexSubscription]
            })
            #expect(calls.withLock { $0.posts } == 1)
        }
    }

    @Test func aFailedRetryPublishesItsErrorAndAllowsAnotherExplicitRetry() async throws {
        let posts = OSAllocatedUnfairLock(initialState: 0)
        try await withSignIns(respond: { request in
            if request.hasPrefix("POST ") {
                posts.withLock { $0 += 1 }
                return (503, "unavailable")
            }
            return (200, request.contains("/v8/management/credentials") ? Self.expired : Self.models)
        }) { signIns, _ in
            for expectedPosts in 1...2 {
                signIns.retry(.codexSubscription)
                #expect(await eventually { await signIns.retrying == nil })
                #expect(posts.withLock { $0 } == expectedPosts)
                #expect(signIns.readiness?.unavailability(for: .codexSubscription)?.disposition == .temporary)
                #expect(signIns.health(among: [.codexSubscription])[.codexSubscription]
                    == signIns.readiness?.unavailability(for: .codexSubscription).map { .unavailable($0) })
            }
        }
    }

    @Test func aPassiveSettingsCheckWithoutAccountsDoesNotStartTheHelper() async {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let supervisor = LocalProxySupervisor(executable: nil, home: home)
        let signIns = SubscriptionSignIns(supervisor: supervisor)

        signIns.refresh()

        #expect(await supervisor.state == .stopped)
        #expect(signIns.selectable == [])
        #expect(signIns.health(among: [.codexSubscription])[.codexSubscription]
            != .checking)
    }
}
