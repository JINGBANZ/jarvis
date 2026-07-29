import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owns one cancellable `screencapture` helper and its transient session-local JPEG.
///
/// `@unchecked Sendable` is justified because `lock` guards `activeCommand` and `cleanupFailed`;
/// each command separately guards its process lifecycle.
public final class ScreenCaptureRunner: @unchecked Sendable {
    public enum Outcome: Sendable {
        case captured(Data)
        case failed
        /// A screen-derived file could not be proven absent. Callers must not attempt a fallback.
        case cleanupFailed
        case cancelled
    }

    /// `@unchecked Sendable` is justified because `lock` guards `started`, `finished`, `cancelled`,
    /// and `identity` — the whole mutable process lifecycle this command owns.
    private final class Command: @unchecked Sendable {
        enum Result {
            case exited(Int32)
            case failed
            case cancelled
        }

        private let lock = NSLock()
        private let process: Process
        private var started = false
        private var finished = false
        private var cancelled = false
        #if canImport(Darwin)
        private var identity: ProcessIdentity?
        #endif

        init(executable: URL, arguments: [String], output: URL) {
            let process = Process()
            // Launch through `sh -c 'umask 077; exec "$0" "$@"'` so the JPEG is owner-only from its
            // first write rather than only from cleanup — a crash mid-capture must not leave a
            // screenshot readable by anyone but the owner. Pre-creating the path `0600` does not
            // work: `screencapture` unlinks and recreates its output file, so the new inode takes
            // the umask (measured on macOS 26.5). The umask has to be the child's, and setting it
            // process-wide would leak into every other thread for the helper's lifetime.
            // Arguments ride as argv via "$0"/"$@" — never interpolated into the script text — so
            // no path can be reinterpreted as shell syntax, and `exec` keeps the pid the
            // cancellation identity checks below rely on.
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments =
                ["-c", "umask 077; exec \"$0\" \"$@\"", executable.path]
                + arguments
                + [output.path]
            self.process = process
        }

        func run() -> Result {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                return .cancelled
            }
            do {
                try process.run()
                started = true
                #if canImport(Darwin)
                identity = Self.processIdentity(process.processIdentifier)
                #endif
                lock.unlock()
            } catch {
                finished = true
                lock.unlock()
                return .failed
            }

            process.waitUntilExit()
            lock.lock()
            finished = true
            let wasCancelled = cancelled
            let status = process.terminationStatus
            lock.unlock()
            return wasCancelled ? .cancelled : .exited(status)
        }

        /// True once cancellation has been requested, whether or not there was still a helper to
        /// signal. The `capture(arguments:)` call that registered this command reads it on the way
        /// out, so a request that loses the race with the helper's exit is still reported by the
        /// capture it belongs to.
        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            // Nothing to signal: the helper either has not launched yet — `run()` checks
            // `cancelled` before spawning — or has already exited.
            guard started, !finished else {
                lock.unlock()
                return
            }
            let processIdentifier = process.processIdentifier
            #if canImport(Darwin)
            let identity = self.identity ?? Self.processIdentity(processIdentifier)
            self.identity = identity
            #endif
            lock.unlock()

            #if canImport(Darwin)
            if let identity, Self.isCurrent(identity) {
                kill(processIdentifier, SIGTERM)
            } else if process.isRunning {
                // A process that exited before either identity read will make `isRunning` false.
                // Otherwise Foundation still owns this exact launched child, so cancellation must
                // not silently become unbounded just because proc_pidinfo was temporarily absent.
                process.terminate()
            }
            #else
            kill(processIdentifier, SIGTERM)
            #endif
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
                #if canImport(Darwin)
                self.forceKillIfNeeded(
                    processIdentifier: processIdentifier,
                    identity: identity)
                #else
                self.forceKillIfNeeded(processIdentifier: processIdentifier)
                #endif
            }
        }

        #if canImport(Darwin)
        private func forceKillIfNeeded(
            processIdentifier: pid_t,
            identity: ProcessIdentity?
        ) {
            lock.lock()
            guard started, !finished else {
                lock.unlock()
                return
            }
            let isOriginalProcess = identity.map(Self.isCurrent) ?? process.isRunning
            if isOriginalProcess {
                kill(processIdentifier, SIGKILL)
            }
            lock.unlock()
        }
        #else
        private func forceKillIfNeeded(processIdentifier: pid_t) {
            lock.lock()
            guard started, !finished else {
                lock.unlock()
                return
            }
            kill(processIdentifier, SIGKILL)
            lock.unlock()
        }
        #endif

        #if canImport(Darwin)
        private struct ProcessIdentity: Sendable, Equatable {
            let processIdentifier: pid_t
            let startedSeconds: UInt64
            let startedMicroseconds: UInt64
        }

        private static func processIdentity(_ processIdentifier: pid_t) -> ProcessIdentity? {
            guard processIdentifier > 0 else { return nil }
            var info = proc_bsdinfo()
            let readBytes = proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                &info,
                Int32(MemoryLayout<proc_bsdinfo>.size))
            guard readBytes == MemoryLayout<proc_bsdinfo>.size else { return nil }
            return ProcessIdentity(
                processIdentifier: processIdentifier,
                startedSeconds: info.pbi_start_tvsec,
                startedMicroseconds: info.pbi_start_tvusec)
        }

        private static func isCurrent(_ identity: ProcessIdentity) -> Bool {
            guard let current = processIdentity(identity.processIdentifier) else { return false }
            return current == identity
        }
        #endif
    }

    private let captureDirectory: URL
    private let executable: URL
    private let lock = NSLock()
    private var activeCommand: Command?
    private var cleanupFailed = false

    public init(captureDirectory: URL) {
        self.captureDirectory = captureDirectory
        self.executable = URL(fileURLWithPath: "/usr/sbin/screencapture")
    }

    init(captureDirectory: URL, executable: URL) {
        self.captureDirectory = captureDirectory
        self.executable = executable
    }

    public func capture(arguments: [String]) -> Outcome {
        let output = captureDirectory
            .appendingPathComponent("capture-\(UUID().uuidString).jpg")
        let command = Command(executable: executable, arguments: arguments, output: output)

        lock.lock()
        guard !cleanupFailed else {
            lock.unlock()
            return .cleanupFailed
        }
        guard activeCommand == nil else {
            lock.unlock()
            return .failed
        }
        activeCommand = command
        lock.unlock()

        let outcome: Outcome
        switch command.run() {
        case let .exited(status) where status == 0:
            if let data = try? Data(contentsOf: output) {
                outcome = .captured(data)
            } else {
                outcome = .failed
            }
        case .cancelled:
            outcome = .cancelled
        case .exited, .failed:
            outcome = .failed
        }

        let removedOutput = removeTransientOutput(output)
        lock.lock()
        // Deregister and read the cancellation flag under one lock hold, so a concurrent
        // `cancelCapture()` either lands first — and is reported here — or finds no active command
        // and is a no-op. It can never survive as a request against some later capture.
        if activeCommand === command {
            activeCommand = nil
        }
        let wasCancelled = command.wasCancelled
        if !removedOutput {
            // Keep this session-local runner poisoned. Even if permissions later change, no future
            // caller may create another screen file while an earlier one remains unaccounted for.
            cleanupFailed = true
        }
        lock.unlock()
        guard removedOutput else { return .cleanupFailed }
        // A request that arrived after the helper had already exited still belongs to this capture:
        // reporting it here is what stops a caller's fallback shot from starting after a Stop.
        return wasCancelled ? .cancelled : outcome
    }

    /// Requests cancellation of the capture that is currently registered. There is deliberately no
    /// pending-request latch: a request can only ever be consumed by the capture it was issued
    /// against, so a request that arrives with nothing in flight is a no-op rather than something a
    /// later, unrelated capture would silently answer with `.cancelled`.
    public func cancelCapture() {
        lock.lock()
        activeCommand?.cancel()
        lock.unlock()
    }

    /// Deletion is part of capture completion, not best-effort deferred work. Verify absence before
    /// the detached producer can release its conversation/session drain boundary.
    private func removeTransientOutput(_ output: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: output.path) else { return true }
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: output.path)
        do {
            try fileManager.removeItem(at: output)
        } catch {
            jlog("Jarvis screen capture: transient JPEG deletion failed: "
                 + error.localizedDescription)
        }
        return !fileManager.fileExists(atPath: output.path)
    }
}
