import Foundation
import JarvisBrainProviders
import JarvisCore
import Testing

@Suite struct LocalProxySignInTests {
    private static let noise = """
        echo 'CLIProxyAPI Version: 7.3.3'
        echo 'To authenticate from a remote machine, an SSH tunnel may be required.'
        echo '  ssh -L 54545:127.0.0.1:54545 root@203.0.113.9 -p 22'
        echo 'Visit the following URL to continue authentication:'
        echo 'https://claude.ai/oauth/authorize?code=true&state=abc'
        echo 'Waiting for Claude authentication callback...'
        """

    private func events(_ stream: AsyncStream<LocalProxySignIn.Event>) async -> [LocalProxySignIn.Event] {
        var events: [LocalProxySignIn.Event] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test func opensThePrintedPageThenReportsTheNewAccount() async throws {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let auth = home.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        let credential = auth.appendingPathComponent("claude-0e6a52df-ada@example.com.json")
        let arguments = home.appendingPathComponent("arguments")
        let login = try proxyStubExecutable(in: home, script: """
            printf '%s\\n' "$@" > '\(arguments.path)'
            \(Self.noise)
            printf '{}' > '\(credential.path)'
            chmod 644 '\(credential.path)'
            exit 0
            """)
        let config = home.appendingPathComponent("config.yaml")
        let signIn = LocalProxySignIn(executable: login, configURL: config, authDirectory: auth)

        let seen = await events(signIn.run(.claudeSubscription))

        #expect(seen.first == .openURL(URL(string: "https://claude.ai/oauth/authorize?code=true&state=abc")!))
        guard case .finished(let accounts) = seen.last else {
            Issue.record("expected the sign-in to finish, got \(seen)")
            return
        }
        #expect(accounts.map(\.email) == ["ada@example.com"])
        #expect(try FileManager.default.attributesOfItem(atPath: credential.path)[.posixPermissions] as? Int
            == 0o600)
        #expect(try String(contentsOf: arguments, encoding: .utf8)
            == "-claude-login\n-no-browser\n-config\n\(config.path)\n")
    }

    @Test func aFailedLoginCarriesTheCommandsLastWords() async throws {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let login = try proxyStubExecutable(in: home, script: """
            \(Self.noise)
            echo 'claude authentication failed: state mismatch' >&2
            exit 1
            """)
        let signIn = LocalProxySignIn(
            executable: login, configURL: home.appendingPathComponent("config.yaml"),
            authDirectory: home)

        let seen = await events(signIn.run(.codexSubscription))

        #expect(seen.count == 2)
        #expect(seen.last == .failed(message: "claude authentication failed: state mismatch"))
    }

    @Test func anAddressJarvisWontOpenEndsTheLogin() async throws {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let login = try proxyStubExecutable(in: home, script: """
            echo 'Visit the following URL to continue authentication:'
            echo 'https://claude.ai.evil.example/oauth/authorize?code=true&state=abc'
            exec /bin/sleep 600
            """)
        let signIn = LocalProxySignIn(
            executable: login, configURL: home.appendingPathComponent("config.yaml"),
            authDirectory: home)

        let seen = await events(signIn.run(.claudeSubscription))

        let opened = seen.contains { event in
            if case .openURL = event { return true }
            return false
        }
        #expect(!opened)
        #expect(seen.last
            == .failed(message: "the sign-in service printed an address Jarvis won't open"))
    }

    @Test func cancellingTheSignInEndsTheLogin() async throws {
        let home = tmp()
        defer { try? FileManager.default.removeItem(at: home) }
        let pidFile = home.appendingPathComponent("pid")
        let login = try proxyStubExecutable(in: home, script: """
            echo $$ > '\(pidFile.path)'
            \(Self.noise)
            exec /bin/sleep 600
            """)
        let signIn = LocalProxySignIn(
            executable: login, configURL: home.appendingPathComponent("config.yaml"),
            authDirectory: home)

        let consumer = Task {
            for await event in signIn.run(.claudeSubscription) {
                if case .openURL = event { return true }
            }
            return false
        }
        #expect(await consumer.value)
        let pid = try #require(Int32(
            try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

        #expect(await eventually { !processExists(pid) })
    }
}
