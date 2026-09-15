import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import JarvisBrainProviders
import JarvisCore

/// Detection runs against a real, throwaway home-directory fixture: executables are actual 0755
/// shell scripts, so Claude auth tests exercise the production subprocess + JSON parsing path.
// Detection deliberately exercises real status-command subprocesses and watchdog teardown. Keep
// those probes sequential so their tight timeout cases do not saturate the process scheduler used by
// other integration suites; the throwaway homes already isolate their filesystem state.
@Suite(.serialized) struct AgentCLIDetectorTests {
    private let fm = FileManager.default

    /// A fresh fake home directory per test.
    private func makeHome() throws -> URL {
        let url = fm.temporaryDirectory
            .appendingPathComponent("AgentCLIDetectorTests-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Create a real executable file at `dir/name`. The default exits without a status document,
    /// which represents an installed CLI whose sign-in state cannot be checked.
    private func installBinary(_ name: String, in dir: URL,
                               script: String = "#!/bin/sh\nexit 2\n") throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(fm.createFile(atPath: dir.appendingPathComponent(name).path,
                              contents: Data(script.utf8),
                              attributes: [.posixPermissions: 0o755]))
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Detector fixtures themselves live under the real system temporary directory. Give each test
    /// a separate synthetic system-temp root so ordinary fake installs remain eligible while tests
    /// can explicitly place a transient wrapper under the rejected root.
    private func detector(home: URL, pathVariable: String?,
                          authStatusTimeout: TimeInterval = 2,
                          temporaryDirectory: URL? = nil) -> AgentCLIDetector {
        AgentCLIDetector(
            home: home,
            pathVariable: pathVariable,
            authStatusTimeout: authStatusTimeout,
            temporaryDirectory: temporaryDirectory
                ?? home.appendingPathComponent("synthetic-system-temporary-directory"),
            applicationDirectories: [home.appendingPathComponent("Applications")]
        )
    }

    /// True when a machine-wide claude/codex lives in the absolute fallback dirs the detector
    /// consults regardless of the fixture home. The negative-detection tests adapt by returning
    /// early — on such a machine, detecting that install is correct behavior, not a failure.
    private var systemWideCLIInstalled: Bool {
        ["/opt/homebrew/bin", "/usr/local/bin"].contains {
            fm.isExecutableFile(atPath: "\($0)/claude") || fm.isExecutableFile(atPath: "\($0)/codex")
        }
    }

    @Test func findsClaudeOnPATH() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("claude", in: bin)
        let d = detector(home: home, pathVariable: "/nonexistent:\(bin.path)")
        let cli = d.detect(.claude)
        #expect(cli?.executableURL.path == bin.appendingPathComponent("claude").path)
        #expect(cli?.authenticationStatus == .unknown)
    }

    @Test func fallsBackToKnownInstallDirsWhenPATHIsMinimal() throws {
        // The app is launched via `open` with launchd's bare PATH — the CLI must still be found in
        // its self-managed install location under the home directory.
        let home = try makeHome()
        try installBinary("claude", in: home.appendingPathComponent(".claude/local"))
        let d = detector(home: home, pathVariable: "/nonexistent")
        #expect(d.detect(.claude)?.executableURL.path
                == home.appendingPathComponent(".claude/local/claude").path)
    }

    @Test func discoversNVMClaudeWithMinimalLaunchdPATH() async throws {
        guard !systemWideCLIInstalled else { return }
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let bin = home.appendingPathComponent(".nvm/versions/node/v20.18.3/bin")
        try installBinary("claude", in: bin, script: "#!/usr/bin/env jarvis-test-node\n")
        try installBinary("jarvis-test-node", in: bin, script: """
            #!/bin/sh
            printf '%s\\n' '{"loggedIn":true}'
            """)
        let cli = detector(home: home, pathVariable: "/usr/bin:/bin").detect(.claude)
        #expect(cli?.executableURL == bin.appendingPathComponent("claude"))
        #expect(cli?.authenticationStatus == .signedIn)
        let executable = try #require(cli?.executableURL)
        let output = try await AgentCLIProcessRunner.run(AgentCLIRun(
            executable: executable, arguments: [], stdin: nil,
            workingDirectory: home, timeout: 10))
        #expect(output.exitCode == 0)
        #expect(output.stdout.contains("\"loggedIn\":true"))
    }

    @Test func nvmDiscoveryUsesNewestInstalledVersionButHonorsPATH() throws {
        guard !systemWideCLIInstalled else { return }
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let older = home.appendingPathComponent(".nvm/versions/node/v9.9.0/bin")
        let newer = home.appendingPathComponent(".nvm/versions/node/v20.18.3/bin")
        // An incomplete newer install and unrelated directories must not hide a usable CLI.
        try write("not executable", to: home.appendingPathComponent(".nvm/versions/node/v30.0.0/bin/claude"))
        try installBinary("claude", in: home.appendingPathComponent(".nvm/versions/node/invalid/bin"))
        try installBinary("claude", in: older)
        try installBinary("claude", in: newer)
        #expect(detector(home: home, pathVariable: "/usr/bin:/bin")
            .detect(.claude)?.executableURL == newer.appendingPathComponent("claude"))
        #expect(detector(home: home, pathVariable: older.path)
            .detect(.claude)?.executableURL == older.appendingPathComponent("claude"))
    }

    @Test(arguments: ["ChatGPT.app", "Codex.app"])
    func discoversBundledCodexWithMinimalLaunchdPATH(app: String) throws {
        guard !systemWideCLIInstalled else { return }
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let resources = home.appendingPathComponent("Applications/\(app)/Contents/Resources")
        try installBinary("codex", in: resources)
        try write("{}", to: home.appendingPathComponent(".codex/auth.json"))
        let cli = detector(home: home, pathVariable: "/usr/bin:/bin").detect(.codex)
        #expect(cli?.executableURL == resources.appendingPathComponent("codex"))
        #expect(cli?.authenticationStatus == .signedIn)
        let standalone = home.appendingPathComponent("standalone")
        try installBinary("codex", in: standalone)
        #expect(detector(home: home, pathVariable: standalone.path).detect(.codex)?.executableURL
                == standalone.appendingPathComponent("codex"))
    }

    @Test func pathTakesPrecedenceOverFallbackDirs() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("codex", in: bin)
        try installBinary("codex", in: home.appendingPathComponent(".cargo/bin"))
        let d = detector(home: home, pathVariable: bin.path)
        #expect(d.detect(.codex)?.executableURL.path == bin.appendingPathComponent("codex").path)
    }

    @Test func skipsExecutableFromSystemTemporaryPATHAndUsesStableInstall() throws {
        let home = try makeHome()
        let temporaryDirectory = home.appendingPathComponent("system-temporary-directory")
        let transientBin = temporaryDirectory.appendingPathComponent("launcher-wrappers")
        let stableBin = home.appendingPathComponent("stable-bin")
        try installBinary("codex", in: transientBin)
        try installBinary("codex", in: stableBin)

        let d = detector(
            home: home,
            pathVariable: "\(transientBin.path):\(stableBin.path)",
            temporaryDirectory: temporaryDirectory
        )

        #expect(d.detect(.codex)?.executableURL.path
                == stableBin.appendingPathComponent("codex").path)
    }

    @Test func nonExecutableFileIsNotDetected() throws {
        guard !systemWideCLIInstalled else { return }
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try write("not a binary", to: bin.appendingPathComponent("claude"))   // 0644, no exec bit
        let d = detector(home: home, pathVariable: bin.path)
        #expect(d.detect(.claude) == nil)
    }

    @Test func claudeAuthStatusCommandReportsSignedIn() throws {
        let home = try makeHome()
        try installBinary("claude", in: home.appendingPathComponent(".claude/local"), script: """
            #!/bin/sh
            printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai"}'
            exit 0
            """)
        let d = detector(home: home, pathVariable: nil, authStatusTimeout: 10)
        #expect(d.detect(.claude)?.authenticationStatus == .signedIn)
    }

    @Test func claudeAuthStatusOverridesStaleOAuthAccountMarker() throws {
        let home = try makeHome()
        try installBinary("claude", in: home.appendingPathComponent(".claude/local"), script: """
            #!/bin/sh
            printf '%s\\n' '{"loggedIn":false,"authMethod":"none"}'
            exit 1
            """)
        try write(#"{"oauthAccount":{"emailAddress":"x@y.z"}}"#,
                  to: home.appendingPathComponent(".claude.json"))
        let d = detector(home: home, pathVariable: nil, authStatusTimeout: 10)
        #expect(d.detect(.claude)?.authenticationStatus == .signedOut)
    }

    @Test func claudeAuthStatusFailureIsUnknown() throws {
        let home = try makeHome()
        try installBinary("claude", in: home.appendingPathComponent(".claude/local"))
        let d = detector(home: home, pathVariable: nil)
        #expect(d.detect(.claude)?.authenticationStatus == .unknown)
    }

    @Test func claudeAuthStatusProbeIsBounded() throws {
        let home = try makeHome()
        try installBinary("claude", in: home.appendingPathComponent(".claude/local"), script: """
            #!/bin/sh
            sleep 1
            """)
        let d = detector(home: home, pathVariable: nil, authStatusTimeout: 0.01)
        #expect(d.detect(.claude)?.authenticationStatus == .unknown)
    }

    @Test func claudeAuthStatusProbeDoesNotWaitForInheritedChildStdout() throws {
        let home = try makeHome()
        let childPID = home.appendingPathComponent("child.pid")
        let childFinished = home.appendingPathComponent("child-finished")
        try installBinary("claude", in: home.appendingPathComponent(".claude/local"), script: """
            #!/bin/sh
            (trap '' HUP; sleep 5; touch "$HOME/child-finished") &
            printf '%s\\n' "$!" > "$HOME/child.pid"
            exit 2
            """)
        let d = detector(home: home, pathVariable: nil, authStatusTimeout: 0.01)

        let status = d.detect(.claude)?.authenticationStatus
        defer {
            if let contents = try? String(contentsOf: childPID, encoding: .utf8),
               let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
        }

        #expect(status == .unknown)
        #expect(!fm.fileExists(atPath: childFinished.path),
                "the auth probe must return without waiting for a child that inherited stdout")
    }

    @Test func codexAuthDetectedViaAuthJSON() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("codex", in: bin)
        try write("{}", to: home.appendingPathComponent(".codex/auth.json"))
        let d = detector(home: home, pathVariable: bin.path, authStatusTimeout: 10)
        #expect(d.detect(.codex)?.authenticationStatus == .signedIn)
        try fm.removeItem(at: home.appendingPathComponent(".codex/auth.json"))
        #expect(d.detect(.codex)?.authenticationStatus == .signedOut)
    }

    @Test func missingBinaryDetectsNothing() throws {
        guard !systemWideCLIInstalled else { return }
        let home = try makeHome()
        let d = detector(home: home, pathVariable: "/nonexistent")
        #expect(d.detect(.claude) == nil)
        #expect(d.detect(.codex) == nil)
    }

    @Test func asyncDetectionReturnsRequestedCLIsInOrder() async throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("claude", in: bin, script: """
            #!/bin/sh
            printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai"}'
            """)
        try installBinary("codex", in: bin)
        let d = detector(home: home, pathVariable: bin.path, authStatusTimeout: 10)
        let result = await d.detectAllAsync([.codex, .claude])
        #expect(result.map(\.cli) == [.codex, .claude])
        #expect(result.last?.authenticationStatus == .signedIn)
    }

    @Test func asyncDetectionProbesOnlyRequestedCLIsOnce() async throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        let claudeProbe = home.appendingPathComponent("claude-probed")
        try installBinary("claude", in: bin, script: """
            #!/bin/sh
            printf 'probe\\n' >> "$HOME/claude-probed"
            printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai"}'
            """)
        try installBinary("codex", in: bin)
        try write("{}", to: home.appendingPathComponent(".codex/auth.json"))
        let d = detector(home: home, pathVariable: bin.path, authStatusTimeout: 10)

        #expect(await d.detectAllAsync([.codex, .codex]).map(\.cli) == [.codex])
        #expect(!fm.fileExists(atPath: claudeProbe.path))

        #expect(await d.detectAllAsync([.claude, .claude]).map(\.cli) == [.claude])
        #expect(try String(contentsOf: claudeProbe, encoding: .utf8) == "probe\n")
    }
}
