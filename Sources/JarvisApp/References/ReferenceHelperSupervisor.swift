import Foundation
import JarvisCore

@MainActor
final class ReferenceHelperSupervisor {
    enum Failure: Error, Equatable { case unavailable, timeout, protocolFailure }
    private let bundle: URL
    private let home: URL
    var homeURL: URL { home }
    #if JARVIS_LIVE_E2E
    private var testFault = false
    var beforeLaunchForTesting: (@MainActor () async -> Void)?
    #endif
    private let startupTimeout: Duration
    private var process: Process?
    private(set) var handshake: Data?
    var processIdentifier: Int32? { process?.processIdentifier }
    var isRunning: Bool { process?.isRunning == true }
    var connectionID: UUID { generation }
    private var input: FileHandle?
    private var decoder = ReferenceFrame()
    private var ledger = ReferenceRequestState()
    private var pending: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var startup: Task<Void, Error>?
    private var stopping: Task<Void, Never>?
    private var stopRevision: UInt = 0
    private var generation = UUID()
    private let writes = DispatchQueue(label: "jarvis.references.write")

    init(bundle: URL, home: URL, startupTimeout: Duration = .seconds(30)) {
        self.bundle = bundle
        self.home = home
        self.startupTimeout = startupTimeout
    }

    #if JARVIS_LIVE_E2E
    convenience init(bundle: URL, home: URL, testFault: Bool, startupTimeout: Duration) {
        self.init(bundle: bundle, home: home, startupTimeout: startupTimeout)
        self.testFault = testFault
    }
    #endif

    func start() async throws {
        let revision = stopRevision
        try Task.checkCancellation()
        if let stopping { await stopping.value }
        try Task.checkCancellation()
        guard revision == stopRevision else { throw CancellationError() }
        if let startup { return try await startup.value }
        if process?.isRunning == true { return }
        let task = Task {
            #if JARVIS_LIVE_E2E
            await self.beforeLaunchForTesting?()
            #endif
            try await self.launch()
        }
        startup = task
        defer { startup = nil }
        try await task.value
    }

    private func launch() async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        let child = Process()
        child.executableURL = bundle.appendingPathComponent("JarvisReferenceHelper")
        child.arguments = [home.path]
        #if JARVIS_LIVE_E2E
        if testFault { child.arguments?.append("--test-fault") }
        #endif
        child.environment = TestCommandOwnership.environment.merging(["HOME": home.path, "TMPDIR": home.appendingPathComponent("staging").path,
                             "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin"]) { _, safe in safe }
        child.currentDirectoryURL = home
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        let launched = UUID()
        generation = launched
        decoder = ReferenceFrame(); ledger.reset()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor in self?.receive(data, generation: launched) }
        }
        // Helper diagnostics have fixed safe messages; draining never copies source data to Activity.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.exited(generation: launched) }
        }
        try TestCommandOwnership.launchChild(child)
        process = child
        input = stdin.fileHandleForWriting
        do {
            let reply = try await request("hello", timeout: startupTimeout)
            handshake = reply
            let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
            guard generation == launched, stopping == nil, child.isRunning,
                  object?["protocol"] as? Int == 1, object?["isolated"] as? Bool == true else {
                throw Failure.protocolFailure
            }
        } catch {
            if stopping == nil { await shutdown() }
            throw error
        }
    }

    func request(_ operation: String, session: UUID? = nil, payload: Data = Data("{}".utf8),
                 timeout: Duration = .seconds(2), cancelOnExpiry: Bool = true) async throws -> Data {
        try Task.checkCancellation()
        guard process?.isRunning == true, let input else { throw Failure.unavailable }
        let id = UUID()
        var object: [String: Any] = ["protocol": 1, "id": id.uuidString.lowercased(),
                                     "operation": operation,
                                     "payload": try JSONSerialization.jsonObject(with: payload)]
        if let session { object["session_id"] = session.uuidString.lowercased() }
        let frame = try ReferenceFrame.encode(JSONSerialization.data(withJSONObject: object))
        try ledger.begin(id)
        let requestedGeneration = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timers[id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.expire(id, failure: Failure.timeout, sendCancel: cancelOnExpiry)
                }
                if Task.isCancelled { expire(id, failure: CancellationError()) }
                writes.async { [weak self] in
                    do { try input.write(contentsOf: frame) } catch {
                        Task { @MainActor in
                            guard self?.generation == requestedGeneration else { return }
                            self?.expire(id, failure: Failure.unavailable, sendCancel: false)
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.expire(id, failure: CancellationError()) }
        }
    }

    private func expire(_ id: UUID, failure: Error, sendCancel: Bool = true) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        ledger.cancel(id)
        timers.removeValue(forKey: id)?.cancel()
        continuation.resume(throwing: failure)
        guard sendCancel else { return }
        Task { [weak self] in
            let payload = Data("{\"request_id\":\"\(id.uuidString.lowercased())\"}".utf8)
            _ = try? await self?.request("cancel", payload: payload, timeout: .seconds(1), cancelOnExpiry: false)
        }
    }

    private func receive(_ data: Data, generation: UUID) {
        guard generation == self.generation else { return }
        do {
            if data.isEmpty { try decoder.finish(); throw Failure.unavailable }
            for frame in try decoder.append(data) {
                let reply = try ReferenceReply(frame)
                let id = reply.id
                guard try ledger.receive(id) else { continue }
                timers.removeValue(forKey: id)?.cancel()
                guard let continuation = pending.removeValue(forKey: id) else { throw Failure.protocolFailure }
                if reply.status == .ok || reply.status == .partial {
                    continuation.resume(returning: reply.result)
                } else { continuation.resume(throwing: Failure.unavailable) }
            }
        } catch {
            failAll(Failure.protocolFailure)
            Task {
                guard self.generation == generation else { return }
                await self.stop()
            }
        }
    }

    private func exited(generation: UUID) {
        guard generation == self.generation else { return }
        failAll(Failure.unavailable)
    }

    private func failAll(_ failure: Error) {
        let calls = pending.values
        pending.removeAll()
        for timer in timers.values { timer.cancel() }
        timers.removeAll(); ledger.reset()
        for call in calls { call.resume(throwing: failure) }
    }

    func stop() async {
        stopRevision &+= 1
        startup?.cancel()
        failAll(Failure.unavailable)
        if let stopping { return await stopping.value }
        let starting = startup
        let task = Task {
            await self.shutdown()
            _ = try? await starting?.value
        }
        stopping = task
        await task.value
        stopping = nil
    }

    private func shutdown() async {
        guard let child = process else { return }
        if child.isRunning { _ = try? await request("shutdown", timeout: .milliseconds(500)) }
        let deadline = ContinuousClock.now + .seconds(2)
        while child.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if child.isRunning { child.terminate() }
        let terminateDeadline = ContinuousClock.now + .milliseconds(200)
        while child.isRunning, ContinuousClock.now < terminateDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        let reapDeadline = ContinuousClock.now + .seconds(1)
        while child.isRunning, ContinuousClock.now < reapDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        generation = UUID()
        try? input?.close()
        failAll(Failure.unavailable)
        process = nil; input = nil
    }
}
