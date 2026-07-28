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
        let control = RunControl(completionEvidence: invocation.completionEvidence)
        do {
            let output = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(with: Result {
                            try runBlocking(invocation, timings: timings, control: control)
                        })
                    }
                }
            } onCancel: {
                control.requestCancellation()
            }
            // A killed run unwinds through the normal exit path; surface Stop as CancellationError
            // rather than a successful completion-signal result or a bogus exit-code result.
            try Task.checkCancellation()
            return output
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
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

    /// Cross-thread requests only wake the blocking process-lifecycle thread; that single owner checks
    /// `Process.isRunning` and sends every signal. No delayed closure retains a numeric pid, so a late
    /// completion signal can never target a different process that reused it.
    private final class RunControl: @unchecked Sendable {
        struct Snapshot {
            let isCancelled: Bool
            let completion: Completion?
        }

        struct Completion {
            let reason: AgentCLICompletionSignal.Reason
            let observedAt: UInt64
        }

        private let lock = NSLock()
        private let wakeup = DispatchSemaphore(value: 0)
        private let completionEvidence: AgentCLICompletionEvidence
        private var isCancelled = false
        private var signalledCompletion: Completion?
        private var stdoutRemainder = Data()
        private var terminalToolUseIDs = Set<String>()
        private var stdoutEvidenceObservedAt: UInt64?

        init(completionEvidence: AgentCLICompletionEvidence) {
            self.completionEvidence = completionEvidence
        }

        func requestCancellation() {
            lock.lock()
            isCancelled = true
            lock.unlock()
            wakeup.signal()
        }

        func requestCompletion(_ reason: AgentCLICompletionSignal.Reason) {
            lock.lock()
            if signalledCompletion == nil {
                signalledCompletion = Completion(
                    reason: reason,
                    observedAt: DispatchTime.now().uptimeNanoseconds)
            }
            lock.unlock()
            wakeup.signal()
        }

        /// Feed complete Claude-style JSONL events into the stronger client-observed evidence gate.
        /// The transport signal and stream event can arrive in either order; termination starts only
        /// after both have been recorded.
        func observeStdout(_ chunk: Data) {
            guard case .stdoutJSONToolResult(let toolNames, let acceptedText) =
                    completionEvidence else {
                return
            }

            var shouldWake = false
            lock.lock()
            if stdoutEvidenceObservedAt == nil {
                stdoutRemainder.append(chunk)
                while let newline = stdoutRemainder.firstIndex(of: 0x0A) {
                    let line = Data(stdoutRemainder[..<newline])
                    stdoutRemainder.removeSubrange(...newline)
                    if recordJSONLineLocked(
                        line,
                        toolNames: toolNames,
                        acceptedText: acceptedText
                    ) {
                        shouldWake = true
                        stdoutRemainder.removeAll(keepingCapacity: false)
                        break
                    }
                }
            }
            lock.unlock()
            if shouldWake {
                wakeup.signal()
            }
        }

        func finishStdout() {
            observeStdout(Data([0x0A]))
        }

        func processDidExit() {
            wakeup.signal()
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(
                isCancelled: isCancelled,
                completion: effectiveCompletionLocked())
        }

        /// Reconstruct completion after a child has already exited and stdout has been drained.
        ///
        /// FileHandle may deliver bytes that the child wrote before exit only after Process reports
        /// that exit. The independent signal must still have arrived while the child was alive, but
        /// matching stdout evidence merely needs to be present in the child's captured output.
        func completionAfterProcessExit(at processExited: UInt64) -> Completion? {
            lock.lock()
            defer { lock.unlock() }
            guard let signalledCompletion,
                  signalledCompletion.observedAt <= processExited else {
                return nil
            }
            switch completionEvidence {
            case .signal:
                return signalledCompletion
            case .stdoutJSONToolResult:
                guard stdoutEvidenceObservedAt != nil else { return nil }
                return signalledCompletion
            }
        }

        func wait(until deadline: UInt64) {
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else { return }
            let remaining = min(deadline - now, UInt64(Int.max))
            _ = wakeup.wait(timeout: .now() + .nanoseconds(Int(remaining)))
        }

        private func effectiveCompletionLocked() -> Completion? {
            guard let signalledCompletion else { return nil }
            switch completionEvidence {
            case .signal:
                return signalledCompletion
            case .stdoutJSONToolResult:
                guard let stdoutEvidenceObservedAt else { return nil }
                return Completion(
                    reason: signalledCompletion.reason,
                    observedAt: max(
                        signalledCompletion.observedAt,
                        stdoutEvidenceObservedAt))
            }
        }

        private func recordJSONLineLocked(
            _ line: Data,
            toolNames: Set<String>,
            acceptedText: String
        ) -> Bool {
            // A capture result can carry a multi-megabyte base64 image in one JSONL line. Avoid
            // decoding that payload for this tiny completion gate; structural validation below
            // still decides every line that contains a terminal tool name or its receipt text.
            let mightContainCompletionEvidence =
                line.range(of: Data(acceptedText.utf8)) != nil
                || toolNames.contains {
                    line.range(of: Data($0.utf8)) != nil
                }
            guard mightContainCompletionEvidence else { return false }

            guard let event = try? JSONSerialization.jsonObject(with: line)
                    as? [String: Any],
                  let type = event["type"] as? String,
                  let message = event["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                return false
            }

            if type == "assistant" {
                for block in content
                where block["type"] as? String == "tool_use" {
                    guard let name = block["name"] as? String,
                          toolNames.contains(name),
                          let id = block["id"] as? String else {
                        continue
                    }
                    terminalToolUseIDs.insert(id)
                }
                return false
            }

            guard type == "user" else { return false }
            for block in content
            where block["type"] as? String == "tool_result" {
                guard block["is_error"] as? Bool != true,
                      let id = block["tool_use_id"] as? String,
                      terminalToolUseIDs.contains(id),
                      Self.toolResultText(block["content"]) == acceptedText else {
                    continue
                }
                stdoutEvidenceObservedAt = DispatchTime.now().uptimeNanoseconds
                return true
            }
            return false
        }

        private static func toolResultText(_ value: Any?) -> String? {
            if let text = value as? String {
                return text
            }
            guard let blocks = value as? [[String: Any]] else {
                return nil
            }
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            return texts.count == 1 ? texts[0] : nil
        }
    }

    private static func runBlocking(_ run: AgentCLIRun, timings: AgentCLIPhaseTimings,
                                    control: RunControl) throws -> AgentCLIOutput {
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
        process.terminationHandler = { _ in
            control.processDidExit()
        }

        // Drain stdout/stderr via readability handlers (they run on FileHandle's own queue) so
        // neither pipe can fill its buffer and stall the child while we block elsewhere — the
        // classic subprocess deadlock. Each signals its semaphore on EOF.
        func drain(
            _ handle: FileHandle,
            into box: Box<Data>,
            done: DispatchSemaphore,
            onFirstByte: (@Sendable () -> Void)? = nil,
            onChunk: (@Sendable (Data) -> Void)? = nil,
            onEOF: (@Sendable () -> Void)? = nil
        ) {
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                    onEOF?()
                    done.signal()
                } else {
                    onFirstByte?()   // no-op after the first stamp; the recorder keeps the earliest
                    onChunk?(chunk)
                    box.set(box.get() + chunk)
                }
            }
        }
        let stdoutBox = Box(Data()), stderrBox = Box(Data())
        let stdoutDone = DispatchSemaphore(value: 0), stderrDone = DispatchSemaphore(value: 0)
        drain(stdoutPipe.fileHandleForReading, into: stdoutBox, done: stdoutDone,
              onFirstByte: { timings.mark(.firstStdoutByte) },
              onChunk: { control.observeStdout($0) },
              onEOF: { control.finishStdout() })
        drain(stderrPipe.fileHandleForReading, into: stderrBox, done: stderrDone)

        let completionObservation = run.completionSignal?.observe {
            control.requestCompletion($0)
        }
        defer { completionObservation?.cancel() }

        try process.run()
        timings.mark(.processLaunched)

        let pid = process.processIdentifier
        let launchedAt = DispatchTime.now().uptimeNanoseconds
        let timeoutNanoseconds = UInt64(max(0, run.timeout) * 1_000_000_000)
        let timeoutDeadline = launchedAt &+ timeoutNanoseconds

        // Feed stdin on its own blocking thread. This keeps the lifecycle owner free to act on Stop
        // or an acknowledged completion even when a child has stopped consuming a pipe-sized prompt.
        #if canImport(Darwin)
        // A provider that exits before reading the prompt must become a normal EPIPE write error,
        // not SIGPIPE terminating the Jarvis process before Swift can preserve the failure timing.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #else
        // Linux has no per-pipe F_SETNOSIGPIPE. Ignore it process-wide so Foundation surfaces
        // EPIPE from the write instead; CLI invocations never use SIGPIPE as application control.
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
        let stdinDone = DispatchSemaphore(value: 0)
        let stdinHandle = stdinPipe.fileHandleForWriting
        let stdin = run.stdin
        DispatchQueue.global(qos: .userInitiated).async {
            var delivered = true
            do {
                if let stdin {
                    try stdinHandle.write(contentsOf: Data(stdin.utf8))
                }
                try stdinHandle.close()
            } catch {
                delivered = false
                try? stdinHandle.close()
            }
            if delivered {
                timings.mark(.stdinDelivered)
            }
            stdinDone.signal()
        }

        enum LifecycleCause {
            case completion(AgentCLICompletionSignal.Reason)
            case timeout
        }
        var lifecycleCause: LifecycleCause?
        var terminationWasRequested = false
        var forceKillDeadline: UInt64?

        func requestTermination(graceNanoseconds: UInt64) {
            let now = DispatchTime.now().uptimeNanoseconds
            if !terminationWasRequested, process.isRunning, kill(pid, SIGTERM) == 0 {
                terminationWasRequested = true
            }
            let deadline = now &+ graceNanoseconds
            if let existing = forceKillDeadline {
                forceKillDeadline = min(existing, deadline)
            } else {
                forceKillDeadline = deadline
            }
        }

        // The lifecycle thread is the only code that signals the pid. Completion/cancellation
        // callbacks merely wake it, and the termination handler wakes it on natural exit.
        while process.isRunning {
            let state = control.snapshot()
            let now = DispatchTime.now().uptimeNanoseconds

            if state.isCancelled {
                requestTermination(graceNanoseconds: 2_000_000_000)
            }
            if !state.isCancelled, lifecycleCause == nil {
                // The transport records when the terminal acknowledgement was observed. Check that
                // timestamp before the watchdog's current time so an acknowledgement just before
                // the deadline cannot be reclassified as a timeout merely because this owner woke
                // a little later.
                if let completion = state.completion,
                   completion.observedAt <= timeoutDeadline {
                    lifecycleCause = .completion(completion.reason)
                    requestTermination(graceNanoseconds: 2_000_000_000)
                } else if now >= timeoutDeadline {
                    lifecycleCause = .timeout
                    requestTermination(graceNanoseconds: 5_000_000_000)
                }
            }

            if let deadline = forceKillDeadline, now >= deadline {
                if process.isRunning {
                    _ = kill(pid, SIGKILL)
                }
                forceKillDeadline = nil
            }
            guard process.isRunning else { break }

            var nextWake = lifecycleCause == nil
                ? timeoutDeadline
                : now &+ 1_000_000_000
            if let forceKillDeadline {
                nextWake = min(nextWake, forceKillDeadline)
            }
            control.wait(until: nextWake)
        }
        process.waitUntilExit()
        let processExited = DispatchTime.now().uptimeNanoseconds
        completionObservation?.cancel()
        // A killed child closes its stdin reader. Give an in-progress large write a bounded chance to
        // observe EPIPE and finish before releasing the pipe object.
        _ = stdinDone.wait(timeout: .now() + 2)
        // EOF normally lands with the exit, but a stray grandchild that inherited the pipes' write
        // ends would hold EOF open until IT dies — bound the wait and take what's been captured
        // (the CLI's own output was written before it exited).
        _ = stdoutDone.wait(timeout: .now() + 2)
        _ = stderrDone.wait(timeout: .now() + 2)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if lifecycleCause == nil {
            // Preserve an acknowledgement that raced natural exit. The observation is cancelled
            // before the drain so a genuinely late host signal cannot retype a finished process.
            // Stdout parsed during this drain was necessarily written by the child before exit.
            if processExited <= timeoutDeadline,
               let completion = control.completionAfterProcessExit(at: processExited),
               completion.observedAt <= timeoutDeadline {
                lifecycleCause = .completion(completion.reason)
            }
        }
        // Finalize exit only after the stdout handler has drained. A very short-lived process can
        // exit before its readability callback is scheduled; the recorder clamps that necessarily
        // pre-exit byte to this captured exit instant instead of dropping the reversed interval.
        timings.mark(.processExited, at: processExited)

        if case .timeout = lifecycleCause {
            let stderr = String(decoding: stderrBox.get(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? "" : "; stderr: \(String(stderr.suffix(2_000)))"
            throw NSError(domain: errorDomain, code: NSURLErrorTimedOut, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(run.executable.lastPathComponent) timed out after \(Int(run.timeout))s\(detail)",
            ])
        }
        let termination: AgentCLIOutput.Termination
        if case .completion(let reason) = lifecycleCause {
            termination = .completionSignal(reason)
        } else {
            termination = .exited
        }
        return AgentCLIOutput(stdout: String(decoding: stdoutBox.get(), as: UTF8.self),
                              stderr: String(decoding: stderrBox.get(), as: UTF8.self),
                              exitCode: process.terminationStatus,
                              termination: termination)
    }
}
