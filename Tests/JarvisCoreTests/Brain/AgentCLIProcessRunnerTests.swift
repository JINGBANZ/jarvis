import Testing
import Foundation
@testable import JarvisCore

@Suite struct AgentCLIProcessRunnerTests {
    @Test func capturesStdinFedStdoutStderrAndExitCode() async throws {
        let run = AgentCLIRun(executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", "cat; echo oops 1>&2; exit 3"],
                              stdin: "hello",
                              workingDirectory: FileManager.default.temporaryDirectory,
                              timeout: 10)
        let output = try await AgentCLIProcessRunner.run(run)
        #expect(output.stdout == "hello")
        #expect(output.stderr.contains("oops"))
        #expect(output.exitCode == 3)
    }

    @Test func cancellingTheTaskKillsTheProcessPromptly() async {
        // Stop pressed mid-turn: the subprocess must die now (SIGTERM, SIGKILL 2s later), not run
        // out its full timeout burning the user's quota.
        let run = AgentCLIRun(executable: URL(fileURLWithPath: "/bin/sleep"),
                              arguments: ["30"], stdin: nil,
                              workingDirectory: FileManager.default.temporaryDirectory,
                              timeout: 60)
        let started = Date()
        let task = Task { try await AgentCLIProcessRunner.run(run) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let result = await task.result
        #expect(Date().timeIntervalSince(started) < 15)   // nowhere near sleep's 30s or the 60s timeout
        guard case .failure(let error) = result else {
            Issue.record("expected a throw, got \(result)"); return
        }
        #expect(error is CancellationError)
    }

    @Test func hungProcessIsTerminatedAtTimeout() async {
        // `exec` replaces the shell instead of forking sleep, so the timeout tests the watchdog and
        // also proves partial provider diagnostics survive into the reported error.
        let run = AgentCLIRun(executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", "echo startup-stalled 1>&2; exec /bin/sleep 30"],
                              stdin: nil,
                              workingDirectory: FileManager.default.temporaryDirectory,
                              timeout: 0.3)
        do {
            _ = try await AgentCLIProcessRunner.run(run)
            Issue.record("expected timeout")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
            #expect(error.localizedDescription.contains("startup-stalled"))
            #expect(AgentCLIProcessRunner.isTimeout(error))
        }
    }
}
