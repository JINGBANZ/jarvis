import Foundation
import JarvisCore
import os
#if canImport(Darwin)
import Darwin
#endif

/// Runs the CLIProxyAPI helper bundled in Jarvis.app, which holds the user's ChatGPT and Claude
/// sign-ins and serves them to `BrainAccessor` as an OpenAI Responses endpoint on 127.0.0.1.
///
/// One instance lives as long as the app. The helper outlives sessions, because it is idle between
/// them and a sign-in made in Settings must reach it, and stops at Quit. The key is fresh for each
/// instance and never persisted outside this launch's owner-only configuration. A helper that exits
/// while running restarts on the same port with the same key after 1, 5, then 15 seconds, so a
/// session composed against the endpoint keeps working through a restart; a fourth exit within ten
/// minutes gives up until the next `ensureRunning()`. A helper that exits before it answers is a
/// failed start, not a crash, and is not retried until asked.
///
/// The helper is one Go process that forks nothing, so plain `Process` launch and signals are
/// enough: no process group, no escalation beyond one SIGKILL.
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
        /// The helper is missing, would not start, or kept stopping. The reason is written to follow
        /// "the sign-in service" in a sentence.
        case failed(reason: String)
    }

    /// What one probe of the helper proves about the subscription targets.
    public enum Readiness: Sendable, Equatable {
        case unavailable(reason: String)
        case ready(Endpoint, signedIn: Set<BrainProvider>)

        public var endpoint: Endpoint? {
            if case .ready(let endpoint, _) = self { endpoint } else { nil }
        }

        /// Why `provider` cannot serve a request now, as the permanent failure a route skips it
        /// with; nil when it can.
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
    /// Sign-ins the user started and has not finished. They are children of Jarvis like the helper,
    /// so Quit ends them too rather than leaving a login waiting on a redirect that can no longer
    /// arrive. Connections can run the Codex and Claude logins at once, so this holds every one:
    /// a single slot lost whichever child started first, and cleared when either finished.
    private nonisolated let signInPIDs = OSAllocatedUnfairLock<Set<Int32>>(initialState: [])

    /// The helper's credential files, owner-only like the API key file.
    public nonisolated var authDirectory: URL { home.appendingPathComponent("auth", isDirectory: true) }
    private nonisolated var runDirectory: URL { home.appendingPathComponent("run", isDirectory: true) }
    /// This launch's configuration. Named by Jarvis's own process id, so a development build and a
    /// release running side by side never rewrite each other's, which the helper would hot-reload.
    public nonisolated var configURL: URL {
        runDirectory.appendingPathComponent("config-\(ProcessInfo.processInfo.processIdentifier).yaml")
    }
    private nonisolated var pidURL: URL {
        runDirectory.appendingPathComponent("helper-\(ProcessInfo.processInfo.processIdentifier).pid")
    }

    /// The helper inside the running app bundle, or, for `swift run` and development tests, the
    /// executable `JARVIS_PROXY_EXECUTABLE` names. Nil only outside a built app with no override,
    /// which makes every subscription target read as missing from this build.
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

    /// Starts the helper unless it runs, and returns once it answers or has failed. Idempotent: a
    /// caller that arrives during a start waits for that start. An explicit call clears a crash
    /// streak that gave up.
    @discardableResult
    public func ensureRunning() async -> State {
        if case .running = state { return state }
        if let startTask { return await startTask.value }
        crashes.removeAll()
        restartTask?.cancel()
        restartTask = nil
        return await start()
    }

    /// Starts the helper if needed and reads its model list once: which subscriptions are signed in.
    public func readiness() async -> Readiness {
        switch await ensureRunning() {
        case .running(let endpoint):
            do {
                let owners = try await Self.modelOwners(at: endpoint)
                return .ready(endpoint, signedIn: Set(BrainProvider.allCases.filter {
                    $0.proxyModelOwner.map(owners.contains) ?? false
                }))
            } catch {
                // The helper is alive but no longer answering. Left `.running`, `ensureRunning`
                // would accept it forever and no retry could replace it, so end it here: the next
                // explicit call starts a fresh one.
                //
                // `stopping` first, because `terminateHelper` suspends: without it the exit reaches
                // `helperExited` while the state still reads `.running`, which counts a crash and
                // arms a restart this method then strands by publishing `.failed`. The port stays,
                // so that next start reuses the endpoint a live session was composed against.
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

    /// A sign-in against this launch's configuration, so the credential lands where the running
    /// helper looks. Nil when the helper cannot start.
    public func makeSignIn() async -> LocalProxySignIn? {
        guard case .running = await ensureRunning(), let executable else { return nil }
        return LocalProxySignIn(executable: executable, configURL: configURL,
                                authDirectory: authDirectory, signInPIDs: signInPIDs)
    }

    public nonisolated func accountFiles(for provider: BrainProvider) -> [LocalProxyAccountFile] {
        LocalProxyAccountFile.all(in: authDirectory, for: provider)
    }

    /// Deletes that subscription's credential files; the running helper notices and stops serving it.
    public nonisolated func signOut(_ provider: BrainProvider) throws {
        for file in accountFiles(for: provider) {
            try FileManager.default.removeItem(at: file.url)
        }
    }

    /// Stops the helper: SIGTERM, then SIGKILL after three seconds.
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

    /// What the helper and its logins run with: an allowlist, not Jarvis's environment minus a few
    /// names. The pinned binary reads `PGSTORE_DSN`, `OBJECTSTORE_*` and `MANAGEMENT_STATIC_PATH`,
    /// any of which would move the OAuth credentials off this Mac, and Go reads `HTTPS_PROXY` and
    /// friends, which would reroute traffic the configuration pins to the vendors. None of that is
    /// Jarvis's to inherit, and no API key is either: the helper authenticates with the per-launch
    /// key in its own configuration.
    static func helperEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        return ["HOME", "PATH", "TMPDIR", "LANG"].reduce(into: [:]) { environment, name in
            environment[name] = inherited[name]
        }
    }

    /// Ends one helper: a signal, a bounded wait for its exit, then a kill. Every path that gives up
    /// on a helper goes through here, so none leaves a process holding this launch's port.
    private func terminateHelper(_ pid: Int32) async {
        kill(pid, SIGTERM)
        let deadline = ContinuousClock.now + Self.stopGrace
        while helperRunning, ContinuousClock.now < deadline {
            // A cancelled caller makes this throw without suspending. Spinning on it would hold the
            // actor that `helperExited` needs to clear `helperRunning`, so the wait would run its
            // full length and then kill a helper that had already exited. Stop waiting instead.
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        if helperRunning { kill(pid, SIGKILL) }
    }

    /// Signals the helper without waiting, for Quit, after which nothing else runs. The next launch
    /// removes the configuration this leaves.
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
        // The helper writes its own rotating logs under its home; nothing reads its console.
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

    /// Polls the model list until it answers: the helper takes a moment to load its credentials and
    /// bind the port.
    private func awaitReady(_ endpoint: Endpoint) async -> State {
        let launched = generation
        let deadline = ContinuousClock.now + Self.readinessDeadline
        var problem = "it didn't answer"
        while ContinuousClock.now < deadline {
            guard launched == generation, !stopping else { return state }
            guard helperRunning else {
                let status = lastExitStatus.map { " with status \($0)" } ?? ""
                // A start that never bound the port may have lost it to another process; the next
                // attempt picks a fresh one rather than failing the same way forever.
                port = nil
                publish(.failed(reason: "stopped\(status) while starting"))
                return state
            }
            do {
                _ = try await Self.modelOwners(at: endpoint)
                // The helper can exit while this probe is in flight, and `helperExited` leaves a
                // start in progress alone. Publishing without re-reading it would latch `.running`
                // on a dead helper, which `ensureRunning` then short-circuits on for the app's life.
                guard launched == generation, !stopping, helperRunning else { return state }
                publish(.running(endpoint))
                return state
            } catch {
                problem = error.localizedDescription
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        // A helper that never answered may also ignore the signal; waiting it out here is what keeps
        // it from holding the port while the next launch tries to bind the same one.
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

    /// The helper creates its own logs directory world-readable, and a build before `commercial-mode`
    /// left a failed call's body there: the transcript and the captured screen text, outside the
    /// session that owns them. Every start narrows the directory and removes those dumps, so
    /// upgrading clears what an older Jarvis wrote.
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

    /// Rewritten at every start. Every value Jarvis depends on is set here rather than left to the
    /// helper's defaults; see wiki/architecture.md for why each is what it is.
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

    /// A Jarvis that ended without Quit (a crash, a force quit) leaves its helper running and its
    /// configuration behind. Stop such a helper, proven to be this executable before it is signaled,
    /// and remove files whose Jarvis is gone; a Jarvis still running keeps its own.
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
        // A development build and a release share this directory. A helper started by the other one
        // is not ours to signal, and its owner's files are how that build finds it again, so both
        // survive; only a helper this executable started is ended and its files removed.
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

    /// A port the kernel reports free on the loopback interface. Another process could take it
    /// before the helper binds; the helper then exits and the start fails with that reason.
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

    /// The vendors the helper lists models for, which are the ones it holds a credential for.
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
