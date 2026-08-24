import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A long-lived newline-delimited subprocess used by the local-agent runtimes.
///
/// Pipe I/O, process waiting, and condition waits stay on dedicated GCD threads. The cooperative
/// executor only awaits continuations, so a quiet or back-pressured app-server/query cannot pin a
/// Swift concurrency thread.
///
/// This boundary stays local because Jarvis needs a handle that outlives one async closure and a
/// synchronous teardown path that identity-checks descendant processes after their leader exits.
/// Swift Subprocess 0.5 does not provide both contracts.
///
/// `@unchecked Sendable` is justified because `condition` guards read/exit/termination state and
/// observed process identities, `writeLock` serializes stdin writes, and the remaining properties
/// are immutable after launch.
final class AgentRuntimeProcess: @unchecked Sendable {
    struct Line: Sendable {
        let text: String
        let observedAt: UInt64
        let byteCount: Int
    }

    static let errorDomain = "AgentRuntimeProcess"
    private static let exitDrainSeconds: TimeInterval = 0.1
    private static let terminationGraceSeconds: TimeInterval = 1
    private static let maxBufferedStdoutBytes = 1_048_576
    private static let maxBufferedStdoutLines = 4_096

    /// `DispatchWorkItem` has no Sendable annotation. This wrapper is safe because the work item is
    /// immutable after initialization and Dispatch makes `cancel()` thread-safe.
    private final class DeadlineTermination: @unchecked Sendable {
        private let workItem: DispatchWorkItem

        init(process: AgentRuntimeProcess) {
            workItem = DispatchWorkItem { [weak process] in
                process?.terminateNow()
            }
        }

        func schedule(at deadline: DispatchTime) {
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: deadline,
                execute: workItem)
        }

        func cancel() {
            workItem.cancel()
        }
    }

    private let condition = NSCondition()
    private let writeLock = NSLock()
    private let processIdentifier: pid_t
    private let platformProcess: Process?
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private var lines: [Line] = []
    private var stdoutRemainder = Data()
    private var bufferedStdoutBytes = 0
    private var stderrTail = Data()
    private var stdoutClosed = false
    private var stdoutOverflowed = false
    private var exitStatus: Int32?
    private var exitObservedAt: Date?
    private var isTerminating = false
    #if canImport(Darwin)
    /// Identities observed while an already-known member still proved that this was the process
    /// group created for this launch. Never populate this from a bare, potentially reused PGID.
    private var knownProcessIdentities: [pid_t: ProcessIdentity] = [:]
    private var hasEscalatedTermination = false
    #endif

    let launchedAt: UInt64

    init(executable: URL, arguments: [String], workingDirectory: URL,
         removingEnvironmentVariables: Set<String> = [],
         environmentOverrides: [String: String] = [:]) throws {
        var environment = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let searchDirectories = AgentCLIDetector.stableSearchDirectories(
            pathVariable: environment["PATH"],
            home: home,
            temporaryDirectory: FileManager.default.temporaryDirectory)
        environment["PATH"] = ([executable.deletingLastPathComponent().path] + searchDirectories)
            .joined(separator: ":")
        environment.removeValue(forKey: "OPENAI_API_KEY")
        for name in removingEnvironmentVariables {
            environment.removeValue(forKey: name)
        }
        for (name, value) in environmentOverrides {
            environment[name] = value
        }

        self.launchedAt = DispatchTime.now().uptimeNanoseconds
        #if canImport(Darwin)
        let spawned = try Self.spawn(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment)
        self.processIdentifier = spawned.processIdentifier
        self.platformProcess = nil
        self.stdin = spawned.stdin
        self.stdout = spawned.stdout
        self.stderr = spawned.stderr
        #else
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        self.processIdentifier = process.processIdentifier
        self.platformProcess = process
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
        self.stderr = stderrPipe.fileHandleForReading
        #endif

        #if canImport(Darwin)
        _ = fcntl(stdin.fileDescriptor, F_SETNOSIGPIPE, 1)
        #else
        _ = signal(SIGPIPE, SIG_IGN)
        #endif

        #if canImport(Darwin)
        if let identity = Self.processIdentity(processIdentifier) {
            condition.lock()
            knownProcessIdentities[identity.processIdentifier] = identity
            condition.unlock()
        }
        scheduleProcessIdentityRefresh()
        startExitMonitor()
        #else
        guard let platformProcess else {
            throw NSError(
                domain: Self.errorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "local agent process was unavailable"])
        }
        platformProcess.terminationHandler = { [weak self] child in
            self?.recordExit(child.terminationStatus)
        }
        #endif

        // Establish termination provenance before callbacks can observe already-buffered output.
        // An immediate stdout overflow is itself a teardown trigger and must have identities to
        // signal rather than permanently latching `isTerminating` with an empty target set.
        stdout.readabilityHandler = { [weak self] handle in
            self?.consumeStdout(handle.availableData)
        }
        stderr.readabilityHandler = { [weak self] handle in
            self?.consumeStderr(handle.availableData)
        }
    }

    deinit {
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
        terminateNow()
        try? stdin.close()
        try? stdout.close()
        try? stderr.close()
    }

    var isRunning: Bool {
        condition.lock()
        defer { condition.unlock() }
        return exitStatus == nil && !isTerminating
    }

    func sendJSONObject(_ object: [String: Any], timeout: TimeInterval) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await sendLine(String(decoding: data, as: UTF8.self), timeout: timeout)
    }

    func sendLine(_ line: String, timeout: TimeInterval) async throws {
        try Task.checkCancellation()
        let boundedTimeout = max(0.01, timeout)
        let deadline = DispatchTime.now() + boundedTimeout
        let data = Data((line + "\n").utf8)
        let deadlineTermination = DeadlineTermination(process: self)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    deadlineTermination.schedule(at: deadline)
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        let result = Result {
                            try write(data)
                            if DispatchTime.now() >= deadline {
                                throw timeoutError(seconds: boundedTimeout)
                            }
                        }
                        deadlineTermination.cancel()
                        continuation.resume(with: result)
                    }
                }
            } onCancel: {
                self.terminateNow()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
    }

    /// Signal end of input. The persistent stream-json protocols keep stdin open for the life of the
    /// process, but a one-shot `codex exec` reads its whole prompt until EOF and will not start work
    /// without it.
    func closeStdin() {
        writeLock.lock()
        defer { writeLock.unlock() }
        try? stdin.close()
    }

    private func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard isRunning else { throw stoppedError() }
        do {
            try stdin.write(contentsOf: data)
        } catch {
            terminateNow()
            throw error
        }
    }

    func nextLine(timeout: TimeInterval) async throws -> Line {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    continuation.resume(with: Result {
                        guard let line = try waitForLine(
                            timeout: timeout,
                            terminateOnTimeout: true
                        ) else {
                            preconditionFailure("a terminating line wait cannot time out softly")
                        }
                        return line
                    })
                }
            }
        } onCancel: {
            self.terminateNow()
        }
    }

    /// Read under a recoverable protocol deadline. Unlike `nextLine`, expiry leaves the process
    /// alive so the owning protocol can interrupt and drain only the timed-out operation.
    func nextLineOrNil(timeout: TimeInterval) async throws -> Line? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    continuation.resume(with: Result {
                        try waitForLine(
                            timeout: timeout,
                            terminateOnTimeout: false)
                    })
                }
            }
        } onCancel: {
            self.terminateNow()
        }
    }

    func terminateNow() {
        condition.lock()
        guard !isTerminating else {
            condition.unlock()
            return
        }
        #if canImport(Darwin)
        let processGroup = processIdentifier
        let currentIdentities = Self.processIdentities(inGroup: processGroup)
        let provesOriginalGroup = currentIdentities.contains { identity in
            knownProcessIdentities[identity.processIdentifier] == identity
        }
        let provesUnreapedLeaderExit = !provesOriginalGroup
            && Self.hasExitedWithoutReaping(processIdentifier)
        if provesOriginalGroup || provesUnreapedLeaderExit {
            for identity in currentIdentities {
                knownProcessIdentities[identity.processIdentifier] = identity
            }
        }
        let terminationTargets = Array(knownProcessIdentities.values)
        let signaledProcessGroup: Bool
        #else
        let target = processIdentifier
        #endif
        isTerminating = true
        condition.broadcast()
        #if canImport(Darwin)
        // The ownership proof and group signal stay under the same lock, so the exit monitor cannot
        // reap the launch leader and make its PGID reusable between those operations. Signaling the
        // verified group closes the enumeration-to-SIGTERM race for a helper forked by the CLI.
        signaledProcessGroup = (provesOriginalGroup || provesUnreapedLeaderExit)
            && killpg(processGroup, SIGTERM) == 0
        #endif
        condition.unlock()

        #if canImport(Darwin)
        if !signaledProcessGroup {
            for identity in terminationTargets
            where Self.isCurrent(identity, inGroup: processGroup) {
                kill(identity.processIdentifier, SIGTERM)
            }
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + Self.terminationGraceSeconds
        ) { [self] in
            condition.lock()
            let currentIdentities = Self.processIdentities(inGroup: processGroup)
            let provesOriginalGroup = currentIdentities.contains { identity in
                terminationTargets.contains(identity)
            }
            let provesUnreapedLeaderExit = !provesOriginalGroup
                && Self.hasExitedWithoutReaping(processIdentifier)
            if provesOriginalGroup || provesUnreapedLeaderExit {
                for identity in currentIdentities {
                    knownProcessIdentities[identity.processIdentifier] = identity
                }
            }
            let escalationTargets = Array(knownProcessIdentities.values)
            let signaledProcessGroup = (provesOriginalGroup || provesUnreapedLeaderExit)
                && killpg(processGroup, SIGKILL) == 0
            hasEscalatedTermination = true
            condition.broadcast()
            condition.unlock()

            if !signaledProcessGroup {
                for identity in escalationTargets
                where Self.isCurrent(identity, inGroup: processGroup) {
                    kill(identity.processIdentifier, SIGKILL)
                }
            }
        }
        #else
        kill(target, SIGTERM)
        let platformProcess = self.platformProcess
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminationGraceSeconds) {
            if platformProcess?.isRunning == true {
                kill(target, SIGKILL)
            }
        }
        #endif
    }

    func diagnosticTail() -> String {
        condition.lock()
        let data = stderrTail
        condition.unlock()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func consumeStdout(_ data: Data) {
        condition.lock()
        var exceededLimit = false
        guard !data.isEmpty else {
            if !stdoutRemainder.isEmpty {
                lines.append(Line(
                    text: String(decoding: stdoutRemainder, as: UTF8.self),
                    observedAt: DispatchTime.now().uptimeNanoseconds,
                    byteCount: stdoutRemainder.count))
                stdoutRemainder.removeAll()
            }
            if bufferedStdoutBytes > Self.maxBufferedStdoutBytes
                || lines.count > Self.maxBufferedStdoutLines {
                stdoutOverflowed = true
                lines.removeAll(keepingCapacity: false)
                stdoutRemainder.removeAll(keepingCapacity: false)
                bufferedStdoutBytes = 0
                exceededLimit = true
            }
            stdoutClosed = true
            stdout.readabilityHandler = nil
            condition.broadcast()
            condition.unlock()
            if exceededLimit {
                terminateNow()
            }
            return
        }
        guard !stdoutOverflowed else {
            condition.unlock()
            return
        }

        bufferedStdoutBytes += data.count
        stdoutRemainder.append(data)
        while let newline = stdoutRemainder.firstIndex(of: 0x0A) {
            let lineData = stdoutRemainder[..<newline]
            stdoutRemainder.removeSubrange(...newline)
            lines.append(Line(
                text: String(decoding: lineData, as: UTF8.self),
                observedAt: DispatchTime.now().uptimeNanoseconds,
                byteCount: lineData.count + 1))
        }
        if bufferedStdoutBytes > Self.maxBufferedStdoutBytes
            || lines.count > Self.maxBufferedStdoutLines {
            stdoutOverflowed = true
            lines.removeAll(keepingCapacity: false)
            stdoutRemainder.removeAll(keepingCapacity: false)
            bufferedStdoutBytes = 0
            exceededLimit = true
        }
        condition.broadcast()
        condition.unlock()
        if exceededLimit {
            terminateNow()
        }
    }

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty else {
            stderr.readabilityHandler = nil
            return
        }
        condition.lock()
        stderrTail.append(data)
        if stderrTail.count > 8_192 {
            stderrTail.removeFirst(stderrTail.count - 8_192)
        }
        condition.unlock()
    }

    private func recordExit(_ status: Int32) {
        condition.lock()
        recordExitLocked(status)
        condition.unlock()
    }

    private func recordExitLocked(_ status: Int32) {
        exitStatus = status
        exitObservedAt = Date()
        condition.broadcast()
    }

    private func waitForLine(
        timeout: TimeInterval,
        terminateOnTimeout: Bool
    ) throws -> Line? {
        let deadline = Date().addingTimeInterval(max(0.01, timeout))
        condition.lock()
        defer { condition.unlock() }
        while lines.isEmpty {
            if stdoutOverflowed {
                throw stdoutOverflowErrorLocked()
            }
            if isTerminating {
                throw CancellationError()
            }
            if let exitStatus {
                if stdoutClosed {
                    throw stoppedErrorLocked(status: exitStatus)
                }
                let drainDeadline = min(
                    deadline,
                    (exitObservedAt ?? Date()).addingTimeInterval(Self.exitDrainSeconds))
                if !condition.wait(until: drainDeadline), lines.isEmpty {
                    throw stoppedErrorLocked(status: exitStatus)
                }
                continue
            }
            guard condition.wait(until: deadline) else {
                guard terminateOnTimeout else { return nil }
                condition.unlock()
                terminateNow()
                condition.lock()
                let detail = diagnosticTailLocked()
                throw NSError(
                    domain: Self.errorDomain,
                    code: NSURLErrorTimedOut,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "local agent runtime timed out after \(Int(timeout))s"
                            + (detail.isEmpty ? "" : "; stderr: \(detail)"),
                    ])
            }
        }
        let line = lines.removeFirst()
        bufferedStdoutBytes = max(0, bufferedStdoutBytes - line.byteCount)
        return line
    }

    private func stoppedError(status: Int32? = nil) -> NSError {
        condition.lock()
        let error = stoppedErrorLocked(status: status)
        condition.unlock()
        return error
    }

    private func stoppedErrorLocked(status: Int32? = nil) -> NSError {
        let knownStatus = status ?? exitStatus
        let detail = diagnosticTailLocked()
        let statusText = knownStatus.map { " (exit \($0))" } ?? ""
        return NSError(
            domain: Self.errorDomain,
            code: Int(knownStatus ?? -1),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "local agent runtime stopped\(statusText)"
                    + (detail.isEmpty ? "" : "; stderr: \(detail)"),
            ])
    }

    private func diagnosticTailLocked() -> String {
        String(decoding: stderrTail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func timeoutError(seconds: TimeInterval) -> NSError {
        NSError(
            domain: Self.errorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "local agent runtime stdin timed out after \(Int(seconds))s",
            ])
    }

    #if canImport(Darwin)
    private struct ProcessIdentity: Sendable, Equatable {
        let processIdentifier: pid_t
        let startedSeconds: UInt64
        let startedMicroseconds: UInt64
    }

    /// Refresh membership while a previously observed identity still proves ownership. This tracks
    /// helpers for teardown after their group leader exits without ever trusting a reused PGID.
    private func scheduleProcessIdentityRefresh() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.refreshProcessIdentities() else { return }
            self.scheduleProcessIdentityRefresh()
        }
    }

    private func refreshProcessIdentities() -> Bool {
        let identities = Self.processIdentities(inGroup: processIdentifier)
        condition.lock()
        defer { condition.unlock() }
        guard !isTerminating, exitStatus == nil else { return false }
        guard identities.contains(where: { identity in
            knownProcessIdentities[identity.processIdentifier] == identity
        }) else {
            return true
        }
        for identity in identities {
            knownProcessIdentities[identity.processIdentifier] = identity
        }
        return true
    }

    private static func processIdentities(inGroup processGroup: pid_t) -> [ProcessIdentity] {
        let requiredBytes = proc_listpids(
            UInt32(PROC_PGRP_ONLY),
            UInt32(processGroup),
            nil,
            0)
        guard requiredBytes > 0 else { return [] }
        var identifiers = [pid_t](
            repeating: 0,
            count: Int(requiredBytes) / MemoryLayout<pid_t>.size + 16)
        let writtenBytes = proc_listpids(
            UInt32(PROC_PGRP_ONLY),
            UInt32(processGroup),
            &identifiers,
            Int32(identifiers.count * MemoryLayout<pid_t>.size))
        guard writtenBytes > 0 else { return [] }
        return identifiers
            .prefix(Int(writtenBytes) / MemoryLayout<pid_t>.size)
            .compactMap(processIdentity)
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

    private static func isCurrent(
        _ identity: ProcessIdentity,
        inGroup processGroup: pid_t
    ) -> Bool {
        guard getpgid(identity.processIdentifier) == processGroup,
              let current = processIdentity(identity.processIdentifier) else {
            return false
        }
        return current.startedSeconds == identity.startedSeconds
            && current.startedMicroseconds == identity.startedMicroseconds
    }

    private struct SpawnedProcess {
        let processIdentifier: pid_t
        let stdin: FileHandle
        let stdout: FileHandle
        let stderr: FileHandle
    }

    /// `Process.run()` does not expose spawn attributes, and calling `setpgid` afterward races exec.
    /// Create the group in `posix_spawn` so every descendant inherits a group Jarvis can terminate.
    private static func spawn(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> SpawnedProcess {
        var stdinDescriptors = [Int32](repeating: 0, count: 2)
        var stdoutDescriptors = [Int32](repeating: 0, count: 2)
        var stderrDescriptors = [Int32](repeating: 0, count: 2)
        guard pipe(&stdinDescriptors) == 0 else { throw posixError(errno) }
        guard pipe(&stdoutDescriptors) == 0 else {
            closeDescriptors(stdinDescriptors)
            throw posixError(errno)
        }
        guard pipe(&stderrDescriptors) == 0 else {
            closeDescriptors(stdinDescriptors)
            closeDescriptors(stdoutDescriptors)
            throw posixError(errno)
        }
        let allDescriptors = stdinDescriptors + stdoutDescriptors + stderrDescriptors
        var shouldCloseAllDescriptors = true
        defer {
            if shouldCloseAllDescriptors {
                closeDescriptors(allDescriptors)
            }
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw posixError(errno)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw posixError(errno)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        for (source, destination) in [
            (stdinDescriptors[0], STDIN_FILENO),
            (stdoutDescriptors[1], STDOUT_FILENO),
            (stderrDescriptors[1], STDERR_FILENO),
        ] {
            let result = posix_spawn_file_actions_adddup2(&actions, source, destination)
            guard result == 0 else { throw posixError(result) }
        }
        for descriptor in allDescriptors {
            let result = posix_spawn_file_actions_addclose(&actions, descriptor)
            guard result == 0 else { throw posixError(result) }
        }
        let chdirResult = workingDirectory.path.withCString {
            posix_spawn_file_actions_addchdir_np(&actions, $0)
        }
        guard chdirResult == 0 else { throw posixError(chdirResult) }

        let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
        guard groupResult == 0 else { throw posixError(groupResult) }
        let flagsResult = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        guard flagsResult == 0 else { throw posixError(flagsResult) }

        let argumentStrings = [executable.path] + arguments
        let environmentStrings = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var processIdentifier: pid_t = 0
        let spawnResult = withCStringArray(argumentStrings) { argumentPointers in
            withCStringArray(environmentStrings) { environmentPointers in
                executable.path.withCString { executablePath in
                    posix_spawn(
                        &processIdentifier,
                        executablePath,
                        &actions,
                        &attributes,
                        argumentPointers,
                        environmentPointers)
                }
            }
        }
        guard spawnResult == 0 else { throw posixError(spawnResult) }

        close(stdinDescriptors[0])
        close(stdoutDescriptors[1])
        close(stderrDescriptors[1])
        shouldCloseAllDescriptors = false
        return SpawnedProcess(
            processIdentifier: processIdentifier,
            stdin: FileHandle(fileDescriptor: stdinDescriptors[1], closeOnDealloc: true),
            stdout: FileHandle(fileDescriptor: stdoutDescriptors[0], closeOnDealloc: true),
            stderr: FileHandle(fileDescriptor: stderrDescriptors[0], closeOnDealloc: true))
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { string in
            string.withCString { strdup($0) }
        }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors {
            close(descriptor)
        }
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    String(cString: strerror(code)),
            ])
    }

    private func startExitMonitor() {
        let processIdentifier = self.processIdentifier
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var exitInformation = siginfo_t()
            var result: Int32
            repeat {
                result = waitid(
                    P_PID,
                    id_t(processIdentifier),
                    &exitInformation,
                    WEXITED | WNOWAIT)
            } while result == -1 && errno == EINTR
            guard result == 0 else { return }
            guard let self else {
                _ = Self.reapExitedProcess(processIdentifier)
                return
            }
            self.recordObservedLeaderExit()
        }
    }

    /// `waitid(P_PID, ..., WNOWAIT)` has observed this launch's exact leader but left it unreaped.
    /// Its PID therefore cannot be recycled, and `posix_spawn` established that same PID as this
    /// launch's PGID. Snapshot member PID/start-time identities before reaping and exposing the exit.
    private func recordObservedLeaderExit() {
        condition.lock()
        let currentIdentities = Self.processIdentities(inGroup: processIdentifier)
        for identity in currentIdentities {
            knownProcessIdentities[identity.processIdentifier] = identity
        }
        // During teardown the unreaped launch leader keeps its PID/PGID unavailable for reuse,
        // preserving group ownership until escalation when a helper could still fork. With no
        // remaining helper, reaping immediately is safe and keeps simple cancellation prompt.
        let hasRemainingHelper = currentIdentities.contains {
            $0.processIdentifier != processIdentifier
        }
        while isTerminating && hasRemainingHelper && !hasEscalatedTermination {
            condition.wait()
        }
        if let status = Self.reapExitedProcess(processIdentifier) {
            recordExitLocked(status)
        }
        condition.unlock()
    }

    private static func reapExitedProcess(_ processIdentifier: pid_t) -> Int32? {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(processIdentifier, &status, 0)
        } while result == -1 && errno == EINTR
        guard result == processIdentifier else { return nil }
        return exitCode(fromWaitStatus: status)
    }

    /// Non-blocking ownership proof for teardown racing the exit monitor. `WNOWAIT` leaves the exact
    /// launch child unreaped, so its PID cannot be recycled while the caller snapshots its group.
    private static func hasExitedWithoutReaping(_ processIdentifier: pid_t) -> Bool {
        var exitInformation = siginfo_t()
        var result: Int32
        repeat {
            result = waitid(
                P_PID,
                id_t(processIdentifier),
                &exitInformation,
                WEXITED | WNOHANG | WNOWAIT)
        } while result == -1 && errno == EINTR
        return result == 0 && exitInformation.si_pid == processIdentifier
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
    #endif

    private func stdoutOverflowErrorLocked() -> NSError {
        NSError(
            domain: Self.errorDomain,
            code: Int(EOVERFLOW),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "local agent runtime stdout exceeded its buffer limit",
            ])
    }
}
