import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Spawns one CLI invocation (`AgentCLIRun`) and captures its output (`AgentCLIOutput`). All
/// blocking work (pipe I/O, `waitUntilExit`) happens on a GCD thread, never the cooperative pool;
/// a watchdog SIGTERMs a hung CLI at `timeout`,
/// and cancelling the calling task (Stop pressed mid-turn) kills the subprocess immediately — a
/// cancelled turn's reply can never be used, so the CLI must not keep burning the user's quota.
public enum AgentCLIProcessRunner {
    static let errorDomain = "AgentCLIProcessRunner"

    /// `timings` is stamped as the run reaches each observable boundary. It is passed in (not
    /// returned) so a cancellation/timeout that unwinds through a throw still leaves the caller the
    /// phases completed before the failure. Defaults to a throwaway recorder for callers that don't
    /// care about phase latency.
    public static func run(_ invocation: AgentCLIRun,
                           timings: AgentCLIPhaseTimings = AgentCLIPhaseTimings()) async throws -> AgentCLIOutput {
        try Task.checkCancellation()   // don't even spawn for an already-cancelled turn
        let pidBox = Box<Int32?>(nil)
        let cancelled = Box(false)
        let output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try runBlocking(invocation, timings: timings,
                                        pidBox: pidBox, cancelled: cancelled)
                    })
                }
            }
        } onCancel: {
            cancelled.set(true)
            if let pid = pidBox.get() { terminate(pid) }
            // else: the process hasn't launched yet — runBlocking re-checks `cancelled` right
            // after launch, closing the race.
        }
        // A killed run unwinds through the normal exit path; surface Stop as CancellationError
        // rather than a bogus exit-code result.
        try Task.checkCancellation()
        return output
    }

    /// SIGTERM now, SIGKILL shortly after for a CLI that ignores SIGTERM. A stale pid is harmless
    /// (ESRCH); 2s is far too short for pid reuse.
    private static func terminate(_ pid: Int32) {
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(pid, SIGKILL) }
    }

    /// An NSLock-guarded cell so the pipe-drain handlers and the watchdog can share state with the
    /// blocking thread. `@unchecked Sendable`: every access goes through the lock.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    }

    private static func runBlocking(_ run: AgentCLIRun, timings: AgentCLIPhaseTimings,
                                    pidBox: Box<Int32?>,
                                    cancelled: Box<Bool>) throws -> AgentCLIOutput {
        timings.mark(.runnerEntered)
        let process = Process()
        process.executableURL = run.executable
        process.arguments = run.arguments
        process.currentDirectoryURL = run.workingDirectory
        // Use the same stable PATH policy as detection, then append the selected CLI's directory so
        // an npm-installed executable can find its interpreter/helpers. Inherited launch wrappers
        // under the system temporary directory must not leak into the long-running app's subprocess.
        var environment = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let searchDirectories = AgentCLIDetector.stableSearchDirectories(
            pathVariable: environment["PATH"],
            home: home,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        environment["PATH"] = ([run.executable.deletingLastPathComponent().path] + searchDirectories)
            .joined(separator: ":")
        // Jarvis's own secret must not widen its exposure: when the documented OPENAI_API_KEY
        // fallback is in use, the transcription key would otherwise be inherited by the brain CLI
        // (and anything its config loads), which authenticates with its own credentials.
        environment.removeValue(forKey: "OPENAI_API_KEY")
        process.environment = environment

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain stdout/stderr via readability handlers (they run on FileHandle's own queue) so
        // neither pipe can fill its buffer and stall the child while we block elsewhere — the
        // classic subprocess deadlock. Each signals its semaphore on EOF.
        func drain(_ handle: FileHandle, into box: Box<Data>, done: DispatchSemaphore,
                   onFirstByte: (@Sendable () -> Void)? = nil) {
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                    done.signal()
                } else {
                    onFirstByte?()   // no-op after the first stamp; the recorder keeps the earliest
                    box.set(box.get() + chunk)
                }
            }
        }
        let stdoutBox = Box(Data()), stderrBox = Box(Data())
        let stdoutDone = DispatchSemaphore(value: 0), stderrDone = DispatchSemaphore(value: 0)
        drain(stdoutPipe.fileHandleForReading, into: stdoutBox, done: stdoutDone,
              onFirstByte: { timings.mark(.firstStdoutByte) })
        drain(stderrPipe.fileHandleForReading, into: stderrBox, done: stderrDone)

        try process.run()
        timings.mark(.processLaunched)

        // Watchdogs by pid (an Int32, so the Sendable closures needn't capture the Process object):
        // SIGTERM at the timeout, SIGKILL shortly after for a CLI that ignores SIGTERM — otherwise
        // `waitUntilExit` below would hang forever despite the timeout.
        let timedOut = Box(false)
        let pid = process.processIdentifier
        // Publish the pid for the caller's cancellation handler, then close the race with a
        // cancel that fired between spawn and publish.
        pidBox.set(pid)
        if cancelled.get() { terminate(pid) }
        let watchdog = DispatchWorkItem {
            timedOut.set(true)
            kill(pid, SIGTERM)
        }
        let killer = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + run.timeout, execute: watchdog)
        DispatchQueue.global().asyncAfter(deadline: .now() + run.timeout + 5, execute: killer)

        // Feeding stdin inline is safe: the output pipes are already draining concurrently, so a
        // prompt larger than the pipe buffer just blocks here until the child consumes it.
        if let stdin = run.stdin {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        }
        try? stdinPipe.fileHandleForWriting.close()
        timings.mark(.stdinDelivered)

        process.waitUntilExit()
        timings.mark(.processExited)
        watchdog.cancel()
        killer.cancel()
        // EOF normally lands with the exit, but a stray grandchild that inherited the pipes' write
        // ends would hold EOF open until IT dies — bound the wait and take what's been captured
        // (the CLI's own output was written before it exited).
        _ = stdoutDone.wait(timeout: .now() + 2)
        _ = stderrDone.wait(timeout: .now() + 2)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Only a SIGTERM exit counts as our timeout — the flag alone could race a normal exit that
        // lands just as the watchdog fires.
        if timedOut.get() && process.terminationReason == .uncaughtSignal {
            let stderr = String(decoding: stderrBox.get(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? "" : "; stderr: \(String(stderr.suffix(2_000)))"
            throw NSError(domain: errorDomain, code: NSURLErrorTimedOut, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(run.executable.lastPathComponent) timed out after \(Int(run.timeout))s\(detail)",
            ])
        }
        return AgentCLIOutput(stdout: String(decoding: stdoutBox.get(), as: UTF8.self),
                              stderr: String(decoding: stderrBox.get(), as: UTF8.self),
                              exitCode: process.terminationStatus)
    }
}
