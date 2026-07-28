import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import JarvisCore

/// Detection runs against a real, throwaway home-directory fixture: executables are actual 0755
/// shell scripts, so Claude auth tests exercise the production subprocess + JSON parsing path.
@Suite struct AgentCLIDetectorTests {
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
                ?? home.appendingPathComponent("synthetic-system-temporary-directory")
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
        let cli = d.detect(.claudeCode)
        #expect(cli?.executableURL.path == bin.appendingPathComponent("claude").path)
        #expect(cli?.authenticationStatus == .unknown)
    }

    @Test func fallsBackToKnownInstallDirsWhenPATHIsMinimal() throws {
        // The app is launched via `open` with launchd's bare PATH — the CLI must still be found in
        // its self-managed install location under the home directory.
        let home = try makeHome()
        try installBinary("claude", in: home.appendingPathComponent(".claude/local"))
        let d = detector(home: home, pathVariable: "/nonexistent")
        #expect(d.detect(.claudeCode)?.executableURL.path
                == home.appendingPathComponent(".claude/local/claude").path)
    }

    @Test func pathTakesPrecedenceOverFallbackDirs() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("codex", in: bin)
        try installBinary("codex", in: home.appendingPathComponent(".cargo/bin"))
        let d = detector(home: home, pathVariable: bin.path)
        #expect(d.detect(.codexCLI)?.executableURL.path == bin.appendingPathComponent("codex").path)
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

        #expect(d.detect(.codexCLI)?.executableURL.path
                == stableBin.appendingPathComponent("codex").path)
    }

    @Test func nonExecutableFileIsNotDetected() throws {
        guard !systemWideCLIInstalled else { return }
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try write("not a binary", to: bin.appendingPathComponent("claude"))   // 0644, no exec bit
        let d = detector(home: home, pathVariable: bin.path)
        #expect(d.detect(.claudeCode) == nil)
    }

    @Test func claudeAuthStatusCommandReportsSignedIn() throws {
        let home = try makeHome()
        try installBinary("claude", in: home.appendingPathComponent(".claude/local"), script: """
            #!/bin/sh
            printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai"}'
            exit 0
            """)
        let d = detector(home: home, pathVariable: nil, authStatusTimeout: 10)
        #expect(d.detect(.claudeCode)?.authenticationStatus == .signedIn)
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
        #expect(d.detect(.claudeCode)?.authenticationStatus == .signedOut)
    }

    @Test func claudeAuthStatusFailureIsUnknown() throws {
        let home = try makeHome()
        try installBinary("claude", in: home.appendingPathComponent(".claude/local"))
        let d = detector(home: home, pathVariable: nil)
        #expect(d.detect(.claudeCode)?.authenticationStatus == .unknown)
    }

    @Test func claudeAuthStatusProbeIsBounded() throws {
        let home = try makeHome()
        try installBinary("claude", in: home.appendingPathComponent(".claude/local"), script: """
            #!/bin/sh
            sleep 1
            """)
        let d = detector(home: home, pathVariable: nil, authStatusTimeout: 0.01)
        #expect(d.detect(.claudeCode)?.authenticationStatus == .unknown)
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

        let status = d.detect(.claudeCode)?.authenticationStatus
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
        let cli = d.detect(.codexCLI)
        #expect(cli?.authenticationStatus == .signedIn)
    }

    @Test func codexFeatureProbeSelectsEnabledNonRemovedSafeNames() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("codex", in: bin, script: """
            #!/bin/sh
            if [ "$1" = "features" ] && [ "$2" = "list" ]; then
                printf '%s\\n' \
                    'shell_tool stable true' \
                    'future-surface under development true' \
                    'retired_surface removed true' \
                    'disabled_surface stable false'
                exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "--help" ]; then
                printf '%s\\n' 'Manage external MCP servers'
                exit 0
            fi
            exit 2
            """)
        let d = detector(home: home, pathVariable: bin.path, authStatusTimeout: 10)

        let cli = d.detect(.codexCLI)

        #expect(cli?.codexFeaturesToDisable == ["shell_tool", "future-surface"])
        #expect(cli?.supportsMCP == true)
    }

    @Test func malformedCodexFeatureOutputFallsBackToPromptOnly() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("codex", in: bin, script: """
            #!/bin/sh
            if [ "$1" = "features" ] && [ "$2" = "list" ]; then
                printf '%s\\n' 'shell_tool stable true' 'unsafe/name stable true'
                exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "--help" ]; then
                printf '%s\\n' 'Manage external MCP servers'
                exit 0
            fi
            exit 2
            """)
        let d = detector(home: home, pathVariable: bin.path, authStatusTimeout: 10)

        let cli = d.detect(.codexCLI)

        #expect(cli?.codexFeaturesToDisable == [])
        // MCP capability is covered independently. This fixture deliberately gives every child
        // probe the short watchdog, so loaded parallel runners may also time out the help process.
    }

    @Test func codexFeatureProbeIsBounded() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("codex", in: bin, script: """
            #!/bin/sh
            if [ "$1" = "features" ] && [ "$2" = "list" ]; then
                exec /bin/sleep 5
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "--help" ]; then
                printf '%s\\n' 'Manage external MCP servers'
                exit 0
            fi
            exit 2
            """)
        // Leave enough room for the independent MCP help process to start under a loaded test
        // runner; only the deliberately stalled feature process should hit this watchdog.
        let d = detector(home: home, pathVariable: bin.path, authStatusTimeout: 1)

        let cli = d.detect(.codexCLI)

        #expect(cli?.codexFeaturesToDisable == [])
        #expect(cli?.supportsMCP == true)
    }

    @Test func oversizedCodexFeatureOutputFallsBackToPromptOnly() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("codex", in: bin, script: """
            #!/bin/sh
            if [ "$1" = "features" ] && [ "$2" = "list" ]; then
                i=0
                while [ "$i" -lt 6000 ]; do
                    printf 'feature_%s stable true\\n' "$i"
                    i=$((i + 1))
                done
                exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "--help" ]; then
                printf '%s\\n' 'Manage external MCP servers'
                exit 0
            fi
            exit 2
            """)
        let d = detector(home: home, pathVariable: bin.path, authStatusTimeout: 10)

        #expect(d.detect(.codexCLI)?.codexFeaturesToDisable == [])
    }

    @Test func installedHelpOutputProvesBasicMCPAvailability() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("claude", in: bin, script: """
            #!/bin/sh
            if [ "$1" = "--help" ]; then
                printf '%s\\n' '  --mcp-config <file>' '  --strict-mcp-config'
                exit 0
            fi
            printf '%s\\n' '{"loggedIn":true}'
            """)
        try installBinary("codex", in: bin, script: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "--help" ]; then
                printf '%s\\n' 'Manage external MCP servers'
                exit 0
            fi
            exit 2
            """)
        let d = detector(home: home, pathVariable: bin.path, authStatusTimeout: 10)

        #expect(d.detect(.claudeCode)?.supportsMCP == true)
        #expect(d.detect(.codexCLI)?.supportsMCP == true)
    }

    @Test func capabilityProbeDrainsOutputWhileTheCLIIsRunning() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("claude", in: bin, script: """
            #!/bin/sh
            if [ "$1" = "--help" ]; then
                printf '%s\\n' '  --mcp-config <file>' '  --strict-mcp-config'
                i=0
                while [ "$i" -lt 6000 ]; do
                    printf '%s\\n' 'bounded probe padding that must not fill and stall the pipe'
                    i=$((i + 1))
                done
                exit 0
            fi
            printf '%s\\n' '{"loggedIn":true}'
            """)
        let d = detector(home: home, pathVariable: bin.path, authStatusTimeout: 5)

        #expect(d.detect(.claudeCode)?.supportsMCP == true)
    }

    @Test func capabilityProbeStopsDrainingInheritedContinuousOutput() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        let childPID = home.appendingPathComponent("probe-child.pid")
        try installBinary("claude", in: bin, script: """
            #!/bin/sh
            if [ "$1" = "--help" ]; then
                printf '%s\\n' '  --mcp-config <file>' '  --strict-mcp-config'
                trap '' HUP
                yes 'inherited probe output must not keep detection alive' &
                writer=$!
                printf '%s\\n' "$writer" > "$HOME/probe-child.pid"
                (sleep 10; kill "$writer" 2>/dev/null) >/dev/null 2>&1 &
                exit 0
            fi
            printf '%s\\n' '{"loggedIn":true}'
            """)
        let d = detector(home: home, pathVariable: bin.path, authStatusTimeout: 20)

        let started = Date()
        let cli = d.detect(.claudeCode)
        let elapsed = Date().timeIntervalSince(started)
        defer {
            if let contents = try? String(contentsOf: childPID, encoding: .utf8),
               let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
        }

        #expect(cli?.supportsMCP == true)
        #expect(elapsed < 8,
                "the capability probe must stop its drain when the parent CLI exits")
    }

    @Test func codexMCPAvailabilityDoesNotDependOnFeatureRegistry() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("codex", in: bin, script: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "--help" ]; then
                printf '%s\\n' 'Manage external MCP servers'
                exit 0
            fi
            exit 2
            """)
        let d = detector(home: home, pathVariable: bin.path, authStatusTimeout: 10)

        let cli = d.detect(.codexCLI)
        #expect(cli?.supportsMCP == true)
        #expect(cli?.codexFeaturesToDisable == [])
    }

    @Test func unfamiliarHelpOutputDoesNotProveMCPAvailability() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("claude", in: bin, script: """
            #!/bin/sh
            if [ "$1" = "--help" ]; then
                printf '%s\\n' 'old help'
                exit 0
            fi
            printf '%s\\n' '{"loggedIn":true}'
            """)
        let d = detector(home: home, pathVariable: bin.path, authStatusTimeout: 10)
        #expect(d.detect(.claudeCode)?.supportsMCP == false)
    }

    @Test func missingBinaryDetectsNothing() throws {
        guard !systemWideCLIInstalled else { return }
        let home = try makeHome()
        let d = detector(home: home, pathVariable: "/nonexistent")
        #expect(d.detect(.claudeCode) == nil)
        #expect(d.detect(.codexCLI) == nil)
    }

    @Test func openAIProviderHasNothingToDetect() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("claude", in: bin)
        try installBinary("codex", in: bin)
        let d = detector(home: home, pathVariable: bin.path)
        #expect(d.detect(.openAI) == nil)
        #expect(d.detectAll().map(\.provider) == [.claudeCode, .codexCLI])
    }

    @Test func asyncDetectionReturnsProbeResults() async throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("claude", in: bin, script: """
            #!/bin/sh
            printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai"}'
            """)
        try installBinary("codex", in: bin)
        let d = detector(home: home, pathVariable: bin.path, authStatusTimeout: 10)
        let result = await d.detectAllAsync()
        #expect(result.first(where: { $0.provider == .claudeCode })?.authenticationStatus == .signedIn)
    }

    @Test func scopedAsyncDetectionProbesOnlyRequestedProvidersOnce() async throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        let claudeProbe = home.appendingPathComponent("claude-probed")
        let codexProbe = home.appendingPathComponent("codex-probed")
        try installBinary("claude", in: bin, script: """
            #!/bin/sh
            printf 'probe\\n' >> "$HOME/claude-probed"
            printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai"}'
            """)
        try installBinary("codex", in: bin, script: """
            #!/bin/sh
            printf 'probe\\n' >> "$HOME/codex-probed"
            exit 2
            """)
        try write("{}", to: home.appendingPathComponent(".codex/auth.json"))
        let d = detector(home: home, pathVariable: bin.path, authStatusTimeout: 10)

        let result = await d.detectAllAsync([.codexCLI, .openAI, .codexCLI])

        #expect(result.map(\.provider) == [.codexCLI])
        #expect(fm.fileExists(atPath: codexProbe.path))
        #expect(!fm.fileExists(atPath: claudeProbe.path))
        #expect(try String(contentsOf: codexProbe, encoding: .utf8) == "probe\nprobe\n")
    }
}
