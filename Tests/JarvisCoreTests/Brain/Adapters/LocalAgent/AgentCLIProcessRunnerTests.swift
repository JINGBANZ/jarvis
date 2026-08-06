import Testing
import Foundation
@testable import JarvisCore

// Every case owns a real subprocess, pipe drains, and watchdog signals. Running all runner stress
// cases together only floods that shared OS boundary and can starve unrelated process integration;
// Swift Testing still runs all non-process suites in parallel.
@Suite(.serialized) struct AgentCLIProcessRunnerTests {
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
        let timings = AgentCLIPhaseTimings()
        let started = Date()
        let task = Task { try await AgentCLIProcessRunner.run(run, timings: timings) }
        #expect(await waitUntil { timings.instant(.processLaunched) != nil })
        task.cancel()
        let result = await task.result
        #expect(Date().timeIntervalSince(started) < 15)   // nowhere near sleep's 30s or the 60s timeout
        guard case .failure(let error) = result else {
            Issue.record("expected a throw, got \(result)"); return
        }
        #expect(error is CancellationError)
    }

    @Test func stampsPhaseTimingsInMonotonicOrder() async throws {
        // The fixture controls the two boundaries the runner can't otherwise observe deterministically:
        // it sleeps, emits its first stdout byte, sleeps again, then exits — so first-output and exit
        // are separated by real, measurable gaps.
        let run = AgentCLIRun(executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", "sleep 0.2; echo ready; sleep 0.2; exit 0"],
                              stdin: "hi",
                              workingDirectory: FileManager.default.temporaryDirectory,
                              timeout: 10)
        let timings = AgentCLIPhaseTimings()
        let output = try await AgentCLIProcessRunner.run(run, timings: timings)
        #expect(output.stdout.contains("ready"))

        let entered = try #require(timings.instant(.runnerEntered))
        let launched = try #require(timings.instant(.processLaunched))
        let stdin = try #require(timings.instant(.stdinDelivered))
        let firstOut = try #require(timings.instant(.firstStdoutByte))
        let exited = try #require(timings.instant(.processExited))
        // Monotonic, in boundary order.
        #expect(entered <= launched)
        #expect(launched <= stdin)
        #expect(stdin <= firstOut)
        #expect(firstOut <= exited)
        // The two 0.2s sleeps land as real gaps (allow slack for scheduling jitter).
        #expect(firstOut - launched >= 150_000_000)   // ~0.2s before the first output byte
        #expect(exited - firstOut >= 150_000_000)      // ~0.2s more before exit
        // replyParsed is a client-side boundary — the runner never stamps it.
        #expect(timings.instant(.replyParsed) == nil)
    }

    @Test func firstStdoutByteStaysUnobservedWithoutStdout() async throws {
        // A run that writes only stderr must leave firstStdoutByte unrecorded (later omitted, not
        // reported as a zero-length time-to-first-output).
        let run = AgentCLIRun(executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", "echo diag 1>&2; exit 0"], stdin: nil,
                              workingDirectory: FileManager.default.temporaryDirectory,
                              timeout: 10)
        let timings = AgentCLIPhaseTimings()
        _ = try await AgentCLIProcessRunner.run(run, timings: timings)
        #expect(timings.instant(.firstStdoutByte) == nil)
        #expect(timings.instant(.processLaunched) != nil)
        #expect(timings.instant(.processExited) != nil)
    }

    @Test func shortLivedStdoutIsOrderedBeforeProcessExit() async throws {
        // A child can write and exit before FileHandle schedules its readability callback. Repeat
        // the smallest such process so captured stdout never produces a reversed or missing phase.
        for _ in 0..<20 {
            let run = AgentCLIRun(executable: URL(fileURLWithPath: "/bin/sh"),
                                  arguments: ["-c", "printf ready"], stdin: nil,
                                  workingDirectory: FileManager.default.temporaryDirectory,
                                  timeout: 10)
            let timings = AgentCLIPhaseTimings()
            let output = try await AgentCLIProcessRunner.run(run, timings: timings)
            #expect(output.stdout == "ready")
            let firstOut = try #require(timings.instant(.firstStdoutByte))
            let exited = try #require(timings.instant(.processExited))
            #expect(firstOut <= exited)
        }
    }

    @Test func stdoutObservedAfterExitIsClampedToTheExitBoundary() throws {
        let timings = AgentCLIPhaseTimings()
        let exited = DispatchTime.now().uptimeNanoseconds
        timings.mark(.firstStdoutByte, at: exited + 1)
        timings.mark(.processExited, at: exited)
        #expect(try #require(timings.instant(.firstStdoutByte)) == exited)
        #expect(try #require(timings.instant(.processExited)) == exited)
    }

    @Test func stdoutObservedBeforeLaunchReturnsIsClampedToTheLaunchBoundary() throws {
        let timings = AgentCLIPhaseTimings()
        let launched = DispatchTime.now().uptimeNanoseconds
        timings.mark(.firstStdoutByte, at: launched - 1)
        timings.mark(.processLaunched, at: launched)
        #expect(try #require(timings.instant(.firstStdoutByte)) == launched)
        #expect(try #require(timings.instant(.processLaunched)) == launched)
    }

    @Test func failedStdinWriteDoesNotClaimPromptDelivery() async throws {
        // Close the child's read end immediately, then make the prompt exceed the pipe buffer so
        // the parent observes EPIPE instead of reporting delivery from a swallowed write error.
        let run = AgentCLIRun(executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", "exec 0<&-; sleep 0.1; exit 2"],
                              stdin: String(repeating: "x", count: 1_000_000),
                              workingDirectory: FileManager.default.temporaryDirectory,
                              timeout: 10)
        let timings = AgentCLIPhaseTimings()
        let output = try await AgentCLIProcessRunner.run(run, timings: timings)
        #expect(output.exitCode == 2)
        #expect(timings.instant(.processLaunched) != nil)
        #expect(timings.instant(.stdinDelivered) == nil)
        #expect(timings.instant(.processExited) != nil)
    }

    @Test func timeoutRetainsPhasesUpToProcessExit() async {
        // The phases observed before the watchdog kill must survive the timeout throw.
        let run = AgentCLIRun(executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", "echo started; exec /bin/sleep 30"], stdin: nil,
                              workingDirectory: FileManager.default.temporaryDirectory,
                              timeout: 0.3)
        let timings = AgentCLIPhaseTimings()
        _ = try? await AgentCLIProcessRunner.run(run, timings: timings)
        #expect(timings.instant(.processLaunched) != nil)
        #expect(timings.instant(.firstStdoutByte) != nil)   // "started" arrived before the stall
        #expect(timings.instant(.processExited) != nil)      // the kill lets waitUntilExit return
    }

    @Test func cancellationRetainsPhasesObservedBeforeTheKill() async {
        // Stop pressed mid-turn: the recorder still holds every phase completed before the kill.
        let run = AgentCLIRun(executable: URL(fileURLWithPath: "/bin/sleep"),
                              arguments: ["30"], stdin: nil,
                              workingDirectory: FileManager.default.temporaryDirectory,
                              timeout: 60)
        let timings = AgentCLIPhaseTimings()
        let task = Task { try await AgentCLIProcessRunner.run(run, timings: timings) }
        #expect(await waitUntil { timings.instant(.processLaunched) != nil })
        task.cancel()
        _ = await task.result
        #expect(timings.instant(.processLaunched) != nil)
        #expect(timings.instant(.processExited) != nil)    // killed → waitUntilExit returns
        #expect(timings.instant(.firstStdoutByte) == nil)   // sleep never writes stdout
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
            #expect(BrainFailure(error).disposition == .temporary)
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
