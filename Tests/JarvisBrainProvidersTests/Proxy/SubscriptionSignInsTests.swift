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
        script: String = "idle",
        respond: @escaping @Sendable (String) -> (Int, String),
        _ body: (SubscriptionSignIns, LocalProxySupervisor) async throws -> Void
    ) async throws {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let supervisor = LocalProxySupervisor(
            executable: try proxyStubExecutable(in: home, script: script), home: home)
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
            for provider in [BrainProvider.codexSubscription, .claudeSubscription] {
                signIns.perform(.signOut, for: provider, openURL: { _ in },
                                willSignOut: { _ in Issue.record("Sign out overlapped credential refresh") })
            }

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
        }) { signIns, supervisor in
            for expectedPosts in 1...2 {
                signIns.retry(.codexSubscription)
                #expect(await eventually { await signIns.retrying == nil })
                #expect(posts.withLock { $0 } == expectedPosts)
                #expect(signIns.readiness?.unavailability(for: .codexSubscription)?.disposition == .temporary)
                #expect(signIns.health(among: [.codexSubscription])[.codexSubscription]
                    == signIns.readiness?.unavailability(for: .codexSubscription).map { .unavailable($0) })
                #expect(supervisor.accountFiles(for: .codexSubscription).count == 1)
                #expect(signIns.connection(for: .codexSubscription).buttons == [.init(.retry), .init(.signOut)])
                #expect(!signIns.connection(for: .codexSubscription).detail.contains("Try again"))
            }
        }
    }

    @Test(arguments: [BrainProvider.codexSubscription, .claudeSubscription])
    func anUnavailableHelperDoesNotBlockLocalSignOutOrAllowDuplicateActions(provider: BrainProvider) async throws {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let supervisor = LocalProxySupervisor(executable: nil, home: home)
        try FileManager.default.createDirectory(at: supervisor.authDirectory, withIntermediateDirectories: true)
        let names: [BrainProvider: String] = [.codexSubscription: "codex-fixture.json", .claudeSubscription: "claude-fixture.json"]
        for name in names.values { try Data("{}".utf8).write(to: supervisor.authDirectory.appendingPathComponent(name)) }
        let signIns = SubscriptionSignIns(supervisor: supervisor)
        signIns.record(.unavailable(reason: "isn't running"))
        var signOuts = 0
        let willSignOut: (BrainProvider) -> Void = { selected in
            #expect(selected == provider)
            #expect(!supervisor.accountFiles(for: provider).isEmpty)
            signOuts += 1
        }

        signIns.perform(.signOut, for: provider, openURL: { _ in Issue.record("Sign out opened a URL") },
                        willSignOut: willSignOut)
        #expect(signIns.connection(for: provider).buttons == [.init(.signOut, title: "Signing out…", isEnabled: false)])
        signIns.perform(.signOut, for: provider, openURL: { _ in }, willSignOut: willSignOut)

        #expect(await eventually { await signIns.connection(for: provider).buttons == [.init(.signIn)] })
        #expect(signOuts == 1)
        #expect(supervisor.accountFiles(for: provider).isEmpty)
        let other: BrainProvider = provider == .codexSubscription ? .claudeSubscription : .codexSubscription
        #expect(supervisor.accountFiles(for: other).count == 1)
        await supervisor.stop()
    }

    @Test func failedSignOutKeepsCredentialsAndItsNextActionClearsTheError() async throws {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let supervisor = LocalProxySupervisor(executable: nil, home: home)
        try FileManager.default.createDirectory(at: supervisor.authDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: supervisor.authDirectory.appendingPathComponent("codex-fixture.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: supervisor.authDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supervisor.authDirectory.path) }
        let signIns = SubscriptionSignIns(supervisor: supervisor)
        signIns.perform(.signOut, for: .codexSubscription, openURL: { _ in }, willSignOut: { _ in })

        #expect(await eventually { await signIns.connection(for: .codexSubscription).detail.hasPrefix("Sign-out failed:") })
        #expect(supervisor.accountFiles(for: .codexSubscription).count == 1)
        #expect(signIns.connection(for: .codexSubscription).buttons == [.init(.retry), .init(.signOut)])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supervisor.authDirectory.path)
        signIns.perform(.signOut, for: .codexSubscription, openURL: { _ in }, willSignOut: { _ in })
        #expect(!signIns.connection(for: .codexSubscription).detail.contains("failed"))
        #expect(await eventually { await signIns.connection(for: .codexSubscription).buttons == [.init(.signIn)] })
        #expect(supervisor.accountFiles(for: .codexSubscription).isEmpty)
        await supervisor.stop()
    }

    @Test func aFailedSignInRetainsTheAccountAndRetryClearsItsError() async throws {
        let posts = OSAllocatedUnfairLock(initialState: 0)
        try await withSignIns(script: """
            case "$*" in *-login*) echo 'fixture sign-in failure'; exit 1 ;; esac
            idle
            """, respond: { request in
            if request.hasPrefix("POST ") { posts.withLock { $0 += 1 }; return (200, "{}") }
            if request.contains("/v8/management/credentials") {
                return (200, posts.withLock { $0 > 0 } ? Self.active : Self.expired)
            }
            return (200, Self.models)
        }) { signIns, supervisor in
            let endpoint = try #require(await supervisor.readiness().endpoint)
            let rejected = ProviderFailure(
                source: .brain(.codexSubscription), stage: .process, category: .authentication,
                disposition: .permanent, identity: .init(), message: "Session ended.")
            signIns.record(.ready(endpoint, signedIn: [], failures: [.codexSubscription: rejected]))
            signIns.perform(.signIn, for: .codexSubscription, openURL: { _ in }, willSignOut: { _ in })
            #expect(signIns.connection(for: .codexSubscription).buttons == [.init(.cancelSignIn)])
            #expect(await eventually {
                let detail = await signIns.connection(for: .codexSubscription).detail
                let readiness = await signIns.readiness
                return detail == "Sign-in failed: fixture sign-in failure" && readiness != nil
            })
            #expect(supervisor.accountFiles(for: .codexSubscription).count == 1)

            signIns.perform(.retry, for: .codexSubscription, openURL: { _ in }, willSignOut: { _ in })

            #expect(!signIns.connection(for: .codexSubscription).detail.contains("Sign-in failed"))
            #expect(await eventually { await signIns.connection(for: .codexSubscription).tone == .ready })
            #expect(posts.withLock { $0 } == 1)
        }
    }

    @Test func cancellingSignInPreservesTheAccountAndRejectsConflictingActions() async throws {
        try await withSignIns(script: """
            case "$*" in *-login*) echo 'https://auth.openai.com/authorize'; idle ;; esac
            idle
            """, respond: { request in
            (200, request.contains("/v8/management/credentials") ? Self.rejected : Self.models)
        }) { signIns, supervisor in
            signIns.record(await supervisor.readiness())
            let opened = OSAllocatedUnfairLock(initialState: false)
            let openURL: (URL) -> Void = { _ in opened.withLock { $0 = true } }
            signIns.perform(.signIn, for: .codexSubscription, openURL: openURL, willSignOut: { _ in })
            #expect(await eventually { opened.withLock { $0 } })
            signIns.perform(.signOut, for: .codexSubscription, openURL: openURL,
                            willSignOut: { _ in Issue.record("Sign out overlapped sign-in") })
            signIns.perform(.retry, for: .codexSubscription, openURL: openURL, willSignOut: { _ in })
            #expect(signIns.retrying == nil)
            signIns.perform(.cancelSignIn, for: .codexSubscription, openURL: openURL, willSignOut: { _ in })

            #expect(await eventually { await signIns.connection(for: .codexSubscription).buttons == [.init(.signIn)] })
            #expect(supervisor.accountFiles(for: .codexSubscription).count == 1)
            #expect(!signIns.connection(for: .codexSubscription).detail.contains("Sign-in failed"))
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
