import Foundation
import JarvisCore

/// Design: wiki/architecture.md#resilience
///
/// Lock order: the adapter's lock and the lifecycle, continuity, and coaching locks all precede
/// this `lock`, which is a leaf: never call the adapter while holding it. Adapters call into those
/// other locks only with their own released.
///
/// `@unchecked Sendable`: mutable state is guarded by `lock`, except `readyTimer`, `pingTimer`, and
/// `pongTimer`, which are read, invalidated, and nilled only on the main queue, never under `lock`.
final class WebSocketConnection: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    struct Lease: Sendable {
        let task: URLSessionWebSocketTask
        let generation: Int
    }

    private enum Retirement {
        case failure(ProviderFailure)
        case expectedRotation(reason: String)
    }

    /// Weak: the adapter owns this connection.
    private weak var adapter: (any WebSocketConnectionAdapter)?
    private let logPrefix: String
    private let source: ProviderFailure.Source
    /// Never names the connect URL: Gemini's carries the API key.
    private let openDetail: String
    private let readyTimeout: TimeInterval
    private let pingInterval: TimeInterval
    private let pongTimeout: TimeInterval
    private let networkStatus: @Sendable () -> String
    private let transportControl: TranscriptionBenchmarkTransportControl?
    private let onStateChange: @Sendable (TranscriptionConnectionState) -> Void

    private let lock = NSLock()
    private var apiKey: String
    private var policy: SocketLifecyclePolicy
    private var session: URLSession?   // retained so stop() can invalidate it (URLSession holds its delegate)
    private var task: URLSessionWebSocketTask?
    private var generation = 0         // rejects late callbacks from a replaced socket
    private var connected = false      // true only between "session ready" and the next drop or close
    private var stopped = true
    private var terminalFailureReported = false
    private var rotationExpected = false
    private var pendingPingGeneration: Int?
    private var readyTimer: Timer?
    private var pingTimer: Timer?
    private var pongTimer: Timer?

    init(
        adapter: any WebSocketConnectionAdapter,
        logPrefix: String,
        source: ProviderFailure.Source,
        openDetail: String,
        apiKey: String,
        policy: SocketLifecyclePolicy,
        readyTimeout: TimeInterval,
        pingInterval: TimeInterval,
        pongTimeout: TimeInterval,
        networkStatus: @escaping @Sendable () -> String,
        transportControl: TranscriptionBenchmarkTransportControl?,
        onStateChange: @escaping @Sendable (TranscriptionConnectionState) -> Void
    ) {
        self.adapter = adapter
        self.logPrefix = logPrefix
        self.source = source
        self.openDetail = openDetail
        self.apiKey = apiKey
        self.policy = policy
        self.readyTimeout = readyTimeout
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
        self.networkStatus = networkStatus
        self.transportControl = transportControl
        self.onStateChange = onStateChange
        super.init()
    }

    // MARK: - Session lifecycle

    func connect() {
        transportControl?.installInterruption { [weak self] in
            self?.interruptForBenchmark() ?? false
        }
        lock.lock()
        stopped = false
        connected = false
        terminalFailureReported = false
        rotationExpected = false
        pendingPingGeneration = nil
        let action = policy.start()
        lock.unlock()
        emitState(.connecting)
        if case .open(let attempt) = action { openSocket(attempt: attempt) }
    }

    func stop() {
        lock.lock()
        stopped = true
        connected = false
        rotationExpected = false
        pendingPingGeneration = nil
        policy.stop()
        let retiredTask = task; task = nil
        let retiredSession = session; session = nil
        generation += 1                 // invalidate every callback retained by the old task
        lock.unlock()
        transportControl?.uninstallInterruption()
        invalidateConnectionTimers()
        if let retiredTask {
            adapter?.connectionWillClose(retiredTask)
            // A user-initiated stop is a normal closure (1000), not "going away" (1001).
            retiredTask.cancel(with: .normalClosure, reason: nil)
        }
        retiredSession?.invalidateAndCancel()   // breaks the URLSession to delegate retain chain
        emitState(.stopped)
    }

    /// Takes effect on the next socket. A healthy socket is deliberately kept so live transcript
    /// state survives a key saved in Settings.
    func updateAPIKey(_ apiKey: String) {
        lock.lock()
        self.apiKey = apiKey
        lock.unlock()
    }

    // MARK: - What the adapter may ask

    var readyLease: Lease? {
        lock.lock(); defer { lock.unlock() }
        guard let task, connected, !stopped else { return nil }
        return Lease(task: task, generation: generation)
    }

    /// True from the moment the socket opens, before readiness.
    func isCurrent(_ lease: Lease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isCurrentLocked(lease)
    }

    func isReady(_ lease: Lease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isCurrentLocked(lease) && connected
    }

    /// Generation alone identifies a socket: it is bumped on every open and every stop.
    func isLive(generation candidate: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isLiveLocked(candidate)
    }

    func isReady(generation candidate: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isLiveLocked(candidate) && connected
    }

    var currentGeneration: Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    /// On a transport error, `completion(false)` runs before the socket is retired, so the adapter
    /// can release its in-flight bookkeeping first.
    func send(
        _ message: URLSessionWebSocketTask.Message,
        on lease: Lease,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        lease.task.send(message) { [weak self] error in
            guard let self else { return }
            guard let error else { completion(true); return }
            completion(false)
            self.retire(lease, .failure(self.transportFailure(error)))
        }
    }

    func acknowledgeReady(_ lease: Lease) {
        lock.lock()
        guard isCurrentLocked(lease), !connected,
              case .ready(let replacement) = policy.acknowledged() else {
            lock.unlock(); return
        }
        connected = true
        rotationExpected = false
        lock.unlock()
        invalidateReadyTimer(lease)
        adapter?.connectionDidBecomeReady(lease, replacement: replacement)
        emitState(.ready)
        startPing(lease)
    }

    /// Only a socket that reached ready can rotate for free. An earlier warning takes the failure
    /// path, or a server that closes every handshake would be reopened forever.
    func noteExpectedRotation(_ lease: Lease, reason: String) {
        lock.lock()
        guard isCurrentLocked(lease), connected, !rotationExpected else { lock.unlock(); return }
        rotationExpected = true
        lock.unlock()
        jlog("\(logPrefix): socket #\(lease.generation) rotating (\(reason))")
    }

    func requestRotation(_ lease: Lease, reason: String) {
        retire(lease, .expectedRotation(reason: reason))
    }

    func fail(_ lease: Lease, cause: ProviderFailure) {
        retire(lease, .failure(cause))
    }

    /// `failure.disposition` must be `.permanent`.
    func reportTerminalFailure(_ failure: ProviderFailure) {
        lock.lock()
        guard !stopped, !terminalFailureReported,
              case .terminate(let cause) = policy.failed(failure) else {
            lock.unlock(); return
        }
        terminalFailureReported = true
        connected = false
        lock.unlock()
        invalidateConnectionTimers()
        emitState(.failed)
        jlog("\(logPrefix): unrecoverable transcription failure "
             + "(\(cause.errorDescription ?? "")), stopping")
        adapter?.connectionDidTerminate(cause)
    }

    private func interruptForBenchmark() -> Bool {
        guard let lease = readyLease else { return false }
        retire(lease, .failure(ProviderFailure(
            source: source, stage: .transport, category: .disconnected,
            disposition: .temporary, identity: .init(),
            message: "benchmark interrupted this transcription transport")))
        return true
    }

    // MARK: - Opening

    private func openSocket(attempt: Int) {
        guard let adapter else { return }
        lock.lock(); let key = apiKey; lock.unlock()
        // Never log this request or its URL: Gemini's carries the key in the query string.
        let request = adapter.makeRequest(apiKey: key)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        lock.lock()
        // A stop can land while the adapter ran `connectionWillRetry`. Installing this socket then
        // would leave one live that nothing cancels.
        guard !stopped else {
            lock.unlock()
            session.invalidateAndCancel()
            return
        }
        let previousSession = self.session
        generation += 1
        let lease = Lease(task: task, generation: generation)
        self.session = session
        self.task = task
        connected = false
        pendingPingGeneration = nil
        rotationExpected = false
        lock.unlock()
        previousSession?.invalidateAndCancel()   // release the previous session's delegate retain
        invalidateConnectionTimers()
        jlog("\(logPrefix): opening socket #\(lease.generation) (attempt \(attempt)) "
             + openDetail)
        adapter.connectionWillOpen(lease)
        task.resume()
        adapter.configureSession(on: lease)
        receiveLoop(lease)
        armReadyTimeout(lease)
    }

    // MARK: - Receiving

    private func receiveLoop(_ lease: Lease) {
        let socketGeneration = lease.generation
        lease.task.receive { [weak self, weak task = lease.task] result in
            guard let self, let task else { return }
            let lease = Lease(task: task, generation: socketGeneration)
            guard self.isCurrent(lease) else { return }
            switch result {
            case .failure(let error):
                // An intentional stop fails the pending receive (ENOTCONN, POSIX 57); ignore that.
                self.lock.lock()
                let isStopped = self.stopped
                let everReady = self.policy.everReady
                self.lock.unlock()
                if isStopped { return }
                guard let adapter = self.adapter else { return }
                // A refused upgrade lands here, status on the task. Vendors reject a bad key only
                // after upgrading, so a refusal is the edge itself: region, VPN, or URL.
                let cause: ProviderFailure
                if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
                    cause = adapter.classifyHandshake(status: status)
                } else {
                    cause = TransportFailureClassifier.classify(
                        error: error, source: self.source, everReady: everReady)
                }
                if cause.disposition == .permanent {
                    self.reportTerminalFailure(cause)
                    return
                }
                self.retire(lease, .failure(cause))
            case .success(let message):
                self.adapter?.handle(message, on: lease)
                self.receiveLoop(lease)
            }
        }
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        lock.lock()
        guard let currentTask = task, currentTask === webSocketTask else { lock.unlock(); return }
        let lease = Lease(task: currentTask, generation: generation)
        let isStopped = stopped
        lock.unlock()
        if isStopped { return }
        guard let adapter else { return }
        if adapter.isExpectedRotation(closeCode: closeCode.rawValue) {
            noteExpectedRotation(lease, reason: "server going away")
        }
        // `reason` is server-supplied: never log it; it reaches Activity only redacted.
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        let cause = adapter.classifyClose(code: closeCode.rawValue, reason: reasonText)
        if cause.disposition == .permanent {
            reportTerminalFailure(cause)
            return
        }
        retire(lease, .failure(cause))
    }

    // MARK: - Retiring a socket

    private func retire(_ lease: Lease, _ retirement: Retirement) {
        lock.lock()
        guard isCurrentLocked(lease), !terminalFailureReported else { lock.unlock(); return }
        var retirement = retirement
        if case .failure(let cause) = retirement, rotationExpected {
            retirement = .expectedRotation(reason: cause.errorDescription ?? "socket failure")
        }
        if case .expectedRotation(let reason) = retirement, !connected {
            lock.unlock()
            jlog("\(logPrefix): socket #\(lease.generation) reported \(reason) before it was "
                 + "ready; waiting for the readiness deadline")
            return
        }
        let action: SocketLifecyclePolicy.Action
        switch retirement {
        case .failure(let cause): action = policy.failed(cause)
        case .expectedRotation: action = policy.expectedRotation()
        }
        connected = false
        pendingPingGeneration = nil
        // Clear the task now: a receive callback may have passed `isCurrent` just before this, and
        // `acknowledgeReady` rechecks the task, so a late acknowledgement cannot revive the socket.
        let retiredSession = session
        task = nil
        session = nil
        if case .terminate = action { terminalFailureReported = true }
        lock.unlock()

        switch action {
        case .open(let attempt), .retry(_, let attempt):
            adapter?.connectionWillRetry(lease, attempt: attempt)
        case .terminate, .ready, .ignore:
            break   // nothing follows a termination, so its salvage is `connectionDidTerminate`
        }
        switch retirement {
        case .failure(let cause): logTransportFailure(cause, generation: lease.generation)
        case .expectedRotation(let reason):
            jlog("\(logPrefix): replacing socket #\(lease.generation) (\(reason))")
        }
        invalidateConnectionTimers()
        lease.task.cancel(with: .goingAway, reason: nil)
        retiredSession?.invalidateAndCancel()

        switch action {
        case .open(let attempt):
            emitState(.reconnecting(attempt: attempt))
            openSocket(attempt: attempt)
        case .retry(let delay, let attempt):
            emitState(.reconnecting(attempt: attempt))
            scheduleReconnect(after: delay, attempt: attempt, from: lease.generation)
        case .terminate(let failure):
            emitState(.failed)
            jlog("\(logPrefix): giving up on socket #\(lease.generation), stopping")
            adapter?.connectionDidTerminate(failure)
        case .ready, .ignore:
            // Unreachable: the lease guard above already rejected the phases that answer these.
            break
        }
    }

    private func scheduleReconnect(after delay: TimeInterval, attempt: Int, from retiredGeneration: Int) {
        let reconnect: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isPending = !self.stopped && self.generation == retiredGeneration
                && self.task == nil && self.isBackingOffLocked
            guard isPending, case .open(let next) = self.policy.retryElapsed() else {
                self.lock.unlock(); return
            }
            self.lock.unlock()
            jlog("\(self.logPrefix): reconnecting (attempt \(attempt))")
            self.openSocket(attempt: next)
        }
        guard let transportControl else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { reconnect() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            transportControl.runReconnectWhenReleased(reconnect)
        }
    }

    // MARK: - Deadlines and liveness

    private func armReadyTimeout(_ lease: Lease) {
        let socketGeneration = lease.generation
        DispatchQueue.main.async { [weak self, weak task = lease.task] in
            guard let self, let task else { return }
            let lease = Lease(task: task, generation: socketGeneration)
            guard self.isPendingReadiness(lease) else { return }
            self.readyTimer?.invalidate()
            self.readyTimer = Timer.scheduledTimer(withTimeInterval: self.readyTimeout, repeats: false) {
                [weak self, weak task] _ in
                guard let self, let task else { return }
                let lease = Lease(task: task, generation: socketGeneration)
                guard self.isPendingReadiness(lease) else { return }
                self.lock.lock(); let everReady = self.policy.everReady; self.lock.unlock()
                self.retire(lease, .failure(TransportFailureClassifier.readinessTimeout(
                    seconds: self.readyTimeout, source: self.source, everReady: everReady)))
            }
        }
    }

    private func startPing(_ lease: Lease) {
        let socketGeneration = lease.generation
        DispatchQueue.main.async { [weak self, weak task = lease.task] in
            guard let self, let task else { return }
            guard self.isReady(Lease(task: task, generation: socketGeneration)) else { return }
            self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: self.pingInterval, repeats: true) {
                [weak self, weak task] _ in
                guard let self, let task else { return }
                self.sendHealthPing(Lease(task: task, generation: socketGeneration))
            }
        }
    }

    private func sendHealthPing(_ lease: Lease) {
        lock.lock()
        guard isCurrentLocked(lease), connected, pendingPingGeneration == nil else {
            lock.unlock(); return
        }
        pendingPingGeneration = lease.generation
        lock.unlock()

        let socketGeneration = lease.generation
        DispatchQueue.main.async { [weak self, weak task = lease.task] in
            guard let self, let task else { return }
            self.pongTimer?.invalidate()
            self.pongTimer = Timer.scheduledTimer(withTimeInterval: self.pongTimeout, repeats: false) {
                [weak self, weak task] _ in
                guard let self, let task else { return }
                let lease = Lease(task: task, generation: socketGeneration)
                self.lock.lock()
                let isStillPending = self.isCurrentLocked(lease) && self.connected
                    && self.pendingPingGeneration == socketGeneration && !self.isBackingOffLocked
                self.lock.unlock()
                guard isStillPending else { return }
                self.retire(lease, .failure(TransportFailureClassifier.livenessTimeout(
                    seconds: self.pongTimeout, source: self.source)))
            }
        }

        lease.task.sendPing { [weak self, weak task = lease.task] error in
            guard let self, let task else { return }
            let lease = Lease(task: task, generation: socketGeneration)
            if let error {
                self.retire(lease, .failure(self.transportFailure(error)))
                return
            }
            self.lock.lock()
            guard self.isCurrentLocked(lease) else { self.lock.unlock(); return }
            self.pendingPingGeneration = nil
            self.lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(lease) else { return }
                self.pongTimer?.invalidate()
                self.pongTimer = nil
            }
        }
    }

    private func invalidateReadyTimer(_ lease: Lease) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(lease) else { return }
            self.readyTimer?.invalidate()
            self.readyTimer = nil
        }
    }

    private func invalidateConnectionTimers() {
        DispatchQueue.main.async { [weak self] in
            self?.readyTimer?.invalidate(); self?.readyTimer = nil
            self?.pingTimer?.invalidate(); self?.pingTimer = nil
            self?.pongTimer?.invalidate(); self?.pongTimer = nil
        }
    }

    // MARK: - Shared guards

    private func isCurrentLocked(_ lease: Lease) -> Bool {
        guard let task, task === lease.task else { return false }
        return !stopped && generation == lease.generation
    }

    private func isLiveLocked(_ candidate: Int) -> Bool {
        !stopped && task != nil && generation == candidate
    }

    private var isBackingOffLocked: Bool {
        if case .backingOff = policy.phase { return true }
        return false
    }

    private func isPendingReadiness(_ lease: Lease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isCurrentLocked(lease) && !connected
    }

    private func transportFailure(_ error: any Error) -> ProviderFailure {
        lock.lock(); let everReady = policy.everReady; lock.unlock()
        return TransportFailureClassifier.classify(
            error: error, source: source, everReady: everReady)
    }

    private func logTransportFailure(_ cause: ProviderFailure, generation socketGeneration: Int) {
        jlog("\(logPrefix) socket #\(socketGeneration) "
             + "\(cause.stage.rawValue) failed: \(cause.errorDescription ?? "") "
             + "(network: \(networkStatus()))")
    }

    private func emitState(_ state: TranscriptionConnectionState) {
        onStateChange(state)
    }
}
