import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import JarvisCore

/// Blocking work runs on a GCD thread, never the cooperative pool. Cancelling kills the CLI at
/// once: a cancelled turn's reply is never used, so the CLI must not keep burning the user's quota.
public enum AgentCLIProcessRunner {
    public static let errorDomain = "AgentCLIProcessRunner"

    /// `timings` is passed in, not returned, so a throw still leaves the caller the phases so far.
    public static func run(_ invocation: AgentCLIRun,
                           timings: AgentCLIPhaseTimings = AgentCLIPhaseTimings()) async throws -> AgentCLIOutput {
        try Task.checkCancellation()
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
            // Not launched yet: runBlocking re-checks `cancelled` right after launch.
        }
        // A killed run unwinds normally, so surface Stop as CancellationError here.
        try Task.checkCancellation()
        return output
    }

    /// SIGKILL follows if SIGTERM is ignored. A stale pid is harmless: 2 s is too short for reuse.
    private static func terminate(_ pid: Int32) {
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(pid, SIGKILL) }
    }

    /// `@unchecked Sendable`: every access goes through the lock.
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
        // Detection's PATH, plus the CLI's own directory so an npm shim finds its interpreter.
        var environment = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let searchDirectories = AgentCLIDetector.stableSearchDirectories(
            pathVariable: environment["PATH"],
            home: home,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        environment["PATH"] = ([run.executable.deletingLastPathComponent().path] + searchDirectories)
            .joined(separator: ":")
        // Jarvis's key must not leak to the CLI, which uses its own credentials.
        environment.removeValue(forKey: "OPENAI_API_KEY")
        process.environment = environment

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain concurrently so a full pipe buffer can't stall the child while this thread blocks.
        func drain(_ handle: FileHandle, into box: Box<Data>, done: DispatchSemaphore,
                   onFirstByte: (@Sendable () -> Void)? = nil) {
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                    done.signal()
                } else {
                    onFirstByte?()   // the recorder keeps only the earliest stamp
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

        // Watchdogs capture only the pid, not the Process. The SIGKILL keeps `waitUntilExit` from
        // hanging on a CLI that ignores SIGTERM.
        let timedOut = Box(false)
        let pid = process.processIdentifier
        // Re-check after publishing, for a cancel that fired between spawn and publish.
        pidBox.set(pid)
        if cancelled.get() { terminate(pid) }
        let watchdog = DispatchWorkItem {
            timedOut.set(true)
            kill(pid, SIGTERM)
        }
        let killer = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + run.timeout, execute: watchdog)
        DispatchQueue.global().asyncAfter(deadline: .now() + run.timeout + 5, execute: killer)

        // Writing stdin inline is safe because the output pipes are already draining.
        #if canImport(Darwin)
        // A CLI that exits before reading must cause EPIPE, not a SIGPIPE that kills Jarvis.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #else
        // Linux has no per-pipe F_SETNOSIGPIPE, so ignore SIGPIPE process-wide.
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
        var stdinDelivered = true
        do {
            if let stdin = run.stdin {
                try stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            }
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            stdinDelivered = false
            try? stdinPipe.fileHandleForWriting.close()
        }
        if stdinDelivered { timings.mark(.stdinDelivered) }

        process.waitUntilExit()
        let processExited = DispatchTime.now().uptimeNanoseconds
        watchdog.cancel()
        killer.cancel()
        // A grandchild holding the pipes' write ends would delay EOF, so bound the wait.
        _ = stdoutDone.wait(timeout: .now() + 2)
        _ = stderrDone.wait(timeout: .now() + 2)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Marked after draining: a short-lived process can exit before its stdout callback runs,
        // and the recorder clamps that byte to this exit instant.
        timings.mark(.processExited, at: processExited)

        // The flag alone could race a normal exit that lands as the watchdog fires.
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
