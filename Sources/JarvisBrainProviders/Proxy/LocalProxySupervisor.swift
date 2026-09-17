import Foundation
import JarvisCore
import os
#if canImport(Darwin)
import Darwin
#endif

// Design: wiki/architecture.md#subscription-targets-through-the-bundled-proxy
/// The helper is one Go process that forks nothing, so plain `Process` signals are enough: no
/// process group, no escalation beyond one SIGKILL.
public actor LocalProxySupervisor {
    public struct Endpoint: Sendable, Equatable {
        public let baseURL: URL
        public let key: String
        public var responsesURL: URL { baseURL.appendingPathComponent("v1/responses") }
        public var modelsURL: URL { baseURL.appendingPathComponent("v1/models") }
    }

    public enum State: Sendable, Equatable {
        case stopped
        case starting
        case running(Endpoint)
        /// `reason` completes the sentence "the sign-in service ...".
        case failed(reason: String)
    }

    public enum Readiness: Sendable, Equatable {
        case unavailable(reason: String)
        case ready(Endpoint, signedIn: Set<BrainProvider>)

        public var endpoint: Endpoint? {
            if case .ready(let endpoint, _) = self { endpoint } else { nil }
        }

        /// The permanent failure a route skips `provider` with, or nil when it can serve now.
        public func unavailability(for provider: BrainProvider) -> ProviderFailure? {
            switch self {
            case .unavailable(let reason):
                return ProviderFailure(
                    source: .brain(provider), stage: .process, category: .unavailable,
                    disposition: .permanent, identity: .init(),
                    message: "the sign-in service \(reason)")
            case .ready(_, let signedIn):
                guard !signedIn.contains(provider) else { return nil }
                return ProviderFailure(
                    source: .brain(provider), stage: .process, category: .authentication,
                    disposition: .permanent, identity: .init(), message: "")
            }
        }
    }

    private static let readinessDeadline: Duration = .seconds(10)
    private static let restartDelays: [Duration] = [.seconds(1), .seconds(5), .seconds(15)]
    private static let crashWindow: TimeInterval = 10 * 60
    private static let stopGrace: Duration = .seconds(3)

    public nonisolated let executable: URL?
    public nonisolated let home: URL
    private let clock: any _Concurrency.Clock<Swift.Duration>
    // Fresh per instance; never persisted outside this launch's owner-only configuration.
    private let key = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }
        .joined()

    public private(set) var state: State = .stopped
    private var port: Int?
    private var process: Process?
    private var generation = 0
    private var helperRunning = false
    private var lastExitStatus: Int32?
    private var stopping = false
    private var crashes: [Date] = []
    private var startTask: Task<State, Never>?
    private var restartTask: Task<Void, Never>?
    private var clearedLeftovers = false
    /// Read by `terminateNow()`, which Quit calls from outside the actor.
    private nonisolated let helperPID = OSAllocatedUnfairLock<Int32?>(initialState: nil)
    /// Every open sign-in, so Quit ends them too. A set: Codex and Claude can sign in at once.
    private nonisolated let signInPIDs = OSAllocatedUnfairLock<Set<Int32>>(initialState: [])

    /// Owner-only: holds the helper's credential files.
    public nonisolated var authDirectory: URL { home.appendingPathComponent("auth", isDirectory: true) }
    private nonisolated var runDirectory: URL { home.appendingPathComponent("run", isDirectory: true) }
    /// Named by Jarvis's process id, so a development build and a release never rewrite each
    /// other's configuration, which the helper would hot-reload.
    public nonisolated var configURL: URL {
        runDirectory.appendingPathComponent("config-\(ProcessInfo.processInfo.processIdentifier).yaml")
    }
    private nonisolated var pidURL: URL {
        runDirectory.appendingPathComponent("helper-\(ProcessInfo.processInfo.processIdentifier).pid")
    }

    /// Nil only outside a built app with no `JARVIS_PROXY_EXECUTABLE` override.
    public static func bundledExecutable() -> URL? {
        Bundle.main.url(forAuxiliaryExecutable: "cliproxyapi")
            ?? ProcessInfo.processInfo.environment["JARVIS_PROXY_EXECUTABLE"].map {
                URL(fileURLWithPath: $0)
            }
    }

    public init(executable: URL?, home: URL, clock: any _Concurrency.Clock<Swift.Duration> = ContinuousClock()) {
        self.executable = executable
        self.home = home
        self.clock = clock
    }

    /// Callers arriving mid-start wait for that start. Clears a crash streak that gave up.
    @discardableResult
    public func ensureRunning() async -> State {
        if case .running = state { return state }
        if let startTask { return await startTask.value }
        crashes.removeAll()
        restartTask?.cancel()
        restartTask = nil
        return await start()
    }

    /// Starts the helper if needed.
    public func readiness() async -> Readiness {
        switch await ensureRunning() {
        case .running(let endpoint):
            do {
                let owners = try await Self.modelOwners(at: endpoint)
                return .ready(endpoint, signedIn: Set(BrainProvider.allCases.filter {
                    $0.proxyModelOwner.map(owners.contains) ?? false
                }))
            } catch {
                // A cancelled probe throws too; don't mistake it for a mute helper and kill it.
                guard !Task.isCancelled, !(error is CancellationError) else {
                    return .unavailable(reason: "isn't running")
                }
                // Left `.running`, a mute helper would never be replaced. Set `stopping` first:
                // the wait suspends, and `helperExited` would otherwise count a crash. The port
                // stays, since live sessions were composed against it.
                jlog("Jarvis proxy: the helper stopped answering — \(error.localizedDescription)")
                stopping = true
                if let pid = helperPID.withLock({ $0 }) { await terminateHelper(pid) }
                publish(.failed(reason: "stopped answering"))
                return .unavailable(reason: "stopped answering")
            }
        case .failed(let reason):
            return .unavailable(reason: reason)
        case .stopped, .starting:
            return .unavailable(reason: "isn't running")
        }
    }

    /// Nil when the helper cannot start.
    public func makeSignIn() async -> LocalProxySignIn? {
        guard case .running = await ensureRunning(), let executable else { return nil }
        return LocalProxySignIn(executable: executable, configURL: configURL,
                                authDirectory: authDirectory, signInPIDs: signInPIDs)
    }

    public nonisolated func accountFiles(for provider: BrainProvider) -> [LocalProxyAccountFile] {
        LocalProxyAccountFile.all(in: authDirectory, for: provider)
    }

    /// The running helper notices the deleted files and stops serving that subscription.
    public nonisolated func signOut(_ provider: BrainProvider) throws {
        for file in accountFiles(for: provider) {
            try FileManager.default.removeItem(at: file.url)
        }
    }

    public func stop() async {
        stopping = true
        restartTask?.cancel()
        restartTask = nil
        if helperRunning, let pid = helperPID.withLock({ $0 }) {
            await terminateHelper(pid)
        }
        try? FileManager.default.removeItem(at: configURL)
        try? FileManager.default.removeItem(at: pidURL)
        publish(.stopped)
    }

    /// An allowlist on purpose: the helper reads `PGSTORE_DSN`, `OBJECTSTORE_*`, and `HTTPS_PROXY`,
    /// which would move credentials or traffic off this Mac. It needs no inherited API key either.
    static func helperEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        return ["HOME", "PATH", "TMPDIR", "LANG"].reduce(into: [:]) { environment, name in
            environment[name] = inherited[name]
        }
    }

    /// Every path that gives up on a helper goes through here, so none leaves it holding the port.
    private func terminateHelper(_ pid: Int32) async {
        kill(pid, SIGTERM)
        let deadline = ContinuousClock.now + Self.stopGrace
        while helperRunning, ContinuousClock.now < deadline {
            // When cancelled, this throws without suspending. Spinning would starve `helperExited`.
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        if helperRunning { kill(pid, SIGKILL) }
    }

    /// For Quit: signals without waiting. The next launch removes the configuration this leaves.
    public nonisolated func terminateNow() {
        if let pid = helperPID.withLock({ $0 }) { kill(pid, SIGTERM) }
        for pid in signInPIDs.withLock({ $0 }) { kill(pid, SIGTERM) }
    }

    // MARK: - Lifecycle

    private func start() async -> State {
        let task = Task { await self.launchAndAwaitReady() }
        startTask = task
        let result = await task.value
        startTask = nil
        return result
    }

    private func launchAndAwaitReady() async -> State {
        guard let executable else {
            publish(.failed(reason: "is missing from this build"))
            return state
        }
        stopping = false
        publish(.starting)
        let endpoint: Endpoint
        do {
            try Self.makeOwnerOnlyDirectory(home)
            try Self.makeOwnerOnlyDirectory(authDirectory)
            try Self.makeOwnerOnlyDirectory(runDirectory)
            Self.lockHelperLogs(in: authDirectory)
            if !clearedLeftovers {
                clearedLeftovers = true
                clearLeftovers(of: executable)
            }
            let port = try self.port ?? Self.freePort()
            self.port = port
            try writeConfiguration(port: port)
            try launch(executable)
            endpoint = Endpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!, key: key)
        } catch {
            jlog("Jarvis proxy: couldn't start the helper — \(error.localizedDescription)")
            port = nil
            publish(.failed(reason: "couldn't start"))
            return state
        }
        return await awaitReady(endpoint)
    }

    private func launch(_ executable: URL) throws {
        generation += 1
        let launched = generation
        let process = Process()
        process.executableURL = executable
        // `-local-model` keeps the model catalog embedded instead of fetched at every start.
        process.arguments = ["-config", configURL.path, "-local-model"]
        process.environment = Self.helperEnvironment()
        // The helper writes its own rotating logs; nothing reads its console.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] exited in
            let status = exited.terminationStatus
            Task { await self?.helperExited(generation: launched, status: status) }
        }
        try process.run()
        self.process = process
        helperRunning = true
        lastExitStatus = nil
        let pid = process.processIdentifier
        helperPID.withLock { $0 = pid }
        try? Data("\(pid)\n".utf8).write(to: pidURL)
    }

    private func awaitReady(_ endpoint: Endpoint) async -> State {
        let launched = generation
        let deadline = ContinuousClock.now + Self.readinessDeadline
        var problem = "it didn't answer"
        while ContinuousClock.now < deadline {
            guard launched == generation, !stopping else { return state }
            guard helperRunning else {
                let status = lastExitStatus.map { " with status \($0)" } ?? ""
                // Another process may hold the port now, so the next start picks a new one.
                port = nil
                publish(.failed(reason: "stopped\(status) while starting"))
                return state
            }
            do {
                _ = try await Self.modelOwners(at: endpoint)
                // The helper can exit mid-probe, and `helperExited` ignores a start in progress.
                // Without this re-check, `.running` would latch on a dead helper.
                guard launched == generation, !stopping, helperRunning else { return state }
                publish(.running(endpoint))
                return state
            } catch {
                problem = error.localizedDescription
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Wait so a helper ignoring the signal can't hold the port the next launch binds.
        if let pid = helperPID.withLock({ $0 }) { await terminateHelper(pid) }
        // Transport detail belongs in the debug log; Activity gets the fixed reason.
        jlog("Jarvis proxy: the helper didn't answer in time — \(problem)")
        port = nil
        publish(.failed(reason: "didn't start in time"))
        return state
    }

    private func helperExited(generation exited: Int, status: Int32) {
        guard exited == generation else { return }
        helperRunning = false
        lastExitStatus = status
        process = nil
        helperPID.withLock { $0 = nil }
        // A start in progress reads the exit itself, and a stop publishes its own state.
        guard case .running = state, !stopping else { return }

        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < Self.crashWindow }
        guard crashes.count < Self.restartDelays.count else {
            publish(.failed(reason: "keeps stopping"))
            return
        }
        let delay = Self.restartDelays[crashes.count]
        crashes.append(now)
        publish(.stopped)
        restartTask = Task { [clock] in
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.restartAfterCrash()
        }
    }

    private func restartAfterCrash() async {
        restartTask = nil
        guard state == .stopped, !stopping, startTask == nil else { return }
        _ = await start()
    }

    private func publish(_ new: State) {
        state = new
    }

    // MARK: - Files

    /// The helper creates its logs directory world-readable, and older builds left failed-call
    /// bodies (transcript and screen text) there. Narrow it and remove those dumps on every start.
    private static func lockHelperLogs(in authDirectory: URL) {
        let logs = authDirectory.appendingPathComponent("logs", isDirectory: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: logs.path) else { return }
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
        let files = (try? manager.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("error-")
            || file.pathExtension == "tmp" {
            try? manager.removeItem(at: file)
        }
    }

    /// Every value Jarvis depends on is set here rather than left to the helper's defaults.
    private func writeConfiguration(port: Int) throws {
        let yaml = """
        host: "127.0.0.1"
        port: \(port)
        auth-dir: "\(authDirectory.path)"
        api-keys:
          - "\(key)"
        debug: false
        # No request or response body ever reaches disk. A coaching request carries the transcript
        # and the captured screen text, and the helper writes a failed call's body to its own logs
        # directory, outside the session that owns that data. This flag is what keeps its
        # request-logging middleware from being installed at all (CLIProxyAPI `server.go`).
        commercial-mode: true
        logging-to-file: true
        logs-max-total-size-mb: 20
        error-logs-max-files: 2
        usage-statistics-enabled: false
        proxy-url: ""
        disable-image-generation: true
        disable-claude-cloak-mode: false
        remote-management:
          allow-remote: false
          secret-key: ""
          disable-control-panel: true
          disable-auto-update-panel: true

        """
        FileManager.default.createFile(
            atPath: configURL.path, contents: Data(yaml.utf8), attributes: [.posixPermissions: 0o600])
        // `createFile` keeps an existing file's mode; set it for a configuration left from before.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    /// A Jarvis that crashed leaves its helper running. Signal it only once proven to be this
    /// executable, and keep the files of any Jarvis still running.
    private nonisolated func clearLeftovers(of executable: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: runDirectory, includingPropertiesForKeys: nil)) ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        func owner(of file: URL) -> Int32? {
            let stem = file.deletingPathExtension().lastPathComponent
            guard let separator = stem.lastIndex(of: "-"),
                  let owner = Int32(stem[stem.index(after: separator)...]),
                  owner != ownPID, kill(owner, 0) != 0, errno == ESRCH else { return nil }
            return owner
        }
        // The other build's helper (dev or release) isn't ours; its files are how it's found.
        var keep: Set<Int32> = []
        for file in files where file.pathExtension == "pid" {
            guard let owner = owner(of: file),
                  let text = try? String(contentsOf: file, encoding: .utf8),
                  let helper = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  kill(helper, 0) == 0 || errno != ESRCH else { continue }
            if Self.executablePath(of: helper) == executable.resolvingSymlinksInPath().path {
                kill(helper, SIGTERM)
            } else {
                keep.insert(owner)
            }
        }
        for file in files {
            guard let owner = owner(of: file), !keep.contains(owner) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func executablePath(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func makeOwnerOnlyDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    // MARK: - Network

    /// Another process could take the port before the helper binds; that start then fails.
    private static func freePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &length)
            }
        }
        guard named == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private struct ModelList: Decodable {
        struct Model: Decodable {
            let id: String
            let owned_by: String?
        }
        let data: [Model]
    }

    private struct ProbeFailure: LocalizedError {
        let errorDescription: String?
    }

    /// The helper lists models only for vendors it holds a credential for.
    private static func modelOwners(at endpoint: Endpoint) async throws -> Set<String> {
        var request = URLRequest(url: endpoint.modelsURL, timeoutInterval: 2)
        request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ProbeFailure(errorDescription: "HTTP \(status)")
        }
        return Set(try JSONDecoder().decode(ModelList.self, from: data).data.compactMap(\.owned_by))
    }
}
