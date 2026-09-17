import Foundation
import JarvisCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Cleanup must be proven before a capture returns. An unprovable cleanup latches this runner, so
/// no later capture starts while a screen-derived file is unaccounted for.
///
/// `@unchecked Sendable`: `lock` guards `activeCommand` and `cleanupFailed`.
public final class ScreenCaptureRunner: @unchecked Sendable {
    public enum Outcome: Sendable {
        case captured(Data)
        case failed
        /// A screen-derived file could not be proven absent. Callers must not attempt a fallback.
        case cleanupFailed
        case cancelled
    }

    /// `@unchecked Sendable`: `lock` guards `started`, `finished`, `cancelled`, and `identity`.
    // Not private: tests drive the cancel-after-exit race, which `capture` can't reliably hit.
    final class Command: @unchecked Sendable {
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
            // The child's umask makes the JPEG owner-only from its first write: `screencapture`
            // recreates its output, so pre-creating it 0600 fails, and a process-wide umask would
            // leak to other threads. Paths ride as argv, never script text, and `exec` keeps the
            // pid the cancellation checks rely on.
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

        /// True once cancellation was requested, even if the helper had already exited.
        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            // Nothing to signal: the helper hasn't launched (`run()` checks first) or has exited.
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
                // `proc_pidinfo` can fail transiently; Foundation still owns this exact child, so
                // cancellation must not become unbounded.
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
        // One lock hold, so a concurrent `cancelCapture()` either lands first and is reported here,
        // or finds no active command. It can never leak into a later capture.
        if activeCommand === command {
            activeCommand = nil
        }
        let wasCancelled = command.wasCancelled
        if !removedOutput {
            // Stay poisoned even if permissions later change.
            cleanupFailed = true
        }
        lock.unlock()
        guard removedOutput else { return .cleanupFailed }
        // A cancel after the helper exited still counts, so no fallback shot starts after a Stop.
        return wasCancelled ? .cancelled : outcome
    }

    /// A no-op with nothing in flight. There is deliberately no pending-request latch, which would
    /// cancel a later, unrelated capture.
    public func cancelCapture() {
        lock.lock()
        activeCommand?.cancel()
        lock.unlock()
    }

    /// Returns whether the file is proven absent. Deletion is part of the capture, not best-effort.
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
