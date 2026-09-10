import Foundation
import JarvisCore

/// One live WebSocket for a transcription stream: the `URLSession`, the task, the generation counter
/// that rejects late callbacks, the readiness deadline, the ping/pong liveness probe, the close and
/// receive paths, and the retry timer. Every decision it makes comes from `SocketLifecyclePolicy`;
/// everything a vendor does differently comes from its `WebSocketConnectionAdapter`.
///
/// It exists because both socket transcribers had grown their own copy of this machinery, and the
/// copies had already drifted apart in four places (issue #279). Readiness, retry budget, and the
/// exhaustion category are now decided once, in Core, under test.
///
/// ## Locks
///
/// Three locks meet here, and the order between them is what keeps the stream's bookkeeping honest:
///
/// - **D**, this type's `lock`, guards socket state: session, task, generation, timers, policy.
/// - **A**, the adapter's own lock, guards stream state: audio buffers, turn coordinators, replay
///   bookkeeping.
/// - **L**, the locks inside `RealtimeTranscriptionLifecycle`, `RealtimeContinuityReporter`, and
///   `TranscriptionCoachingCoordinator`.
///
/// The order is A then D, L then D, and A then L only with A released. **D is a leaf: this type
/// never calls an adapter method while holding `lock`.**
///
/// That is what lets an adapter mirror readiness in its own A-guarded state and have producers read
/// only the mirror. Each state change here is immediately followed by an adapter callback that takes
/// A and flips the mirror, so a producer holding A sees either the whole pre-change picture or the
/// whole post-change one, never a half-applied handoff. This connection's answers (`isReady`,
/// `readyLease`, `isCurrent`) say which socket to address, never what the stream should record; a
/// stale answer always means "that socket died a moment ago", and `connectionWillRetry` needs A, so
/// it always runs after the producer it raced and requeues whatever that producer did.
///
/// `@unchecked Sendable`: every mutable field is guarded by `lock` except `readyTimer`, `pingTimer`,
/// and `pongTimer`. Those are created, read, invalidated, and nilled only from main-queue blocks,
/// including inside `stop()`, which hops to main rather than touching them under `lock`. Main-queue
/// confinement is what makes them safe: reading them under `lock` and hopping to main only for the
/// `invalidate()` call would race an off-main stop against a main-queue writer assigning a
/// replacement timer. `stopped` is set before that hop and every timer body re-checks it, so a timer
/// firing in the gap does nothing.
final class WebSocketConnection: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// One socket's identity: the task to address and the generation that authorizes it. A callback
    /// carrying a stale lease is from a socket that has already been replaced.
    struct Lease: Sendable {
        let task: URLSessionWebSocketTask
        let generation: Int
    }

    /// Why a socket is being retired. An expected rotation costs no retry budget and reports nothing
    /// to the user; a failure consults the budget and may end the stream.
    private enum Retirement {
        case failure(ProviderFailure)
        case expectedRotation(reason: String)
    }

    /// Weak, because the adapter owns this connection: see the protocol's header. Every callback
    /// through it is a no-op once the adapter is gone, which is the right answer for a `URLSession`
    /// that outlived its stream.
    private weak var adapter: (any WebSocketConnectionAdapter)?
    /// Prefix for every diagnostic line about this socket, for example `Jarvis realtime [me]`.
    private let logPrefix: String
    /// This stream's identity in every failure this connection classifies.
    private let source: ProviderFailure.Source
    /// Detail appended to the "opening socket" line. Never names the connect URL: Gemini's carries
    /// the API key in its query string.
    private let openDetail: String
    private let readyTimeout: TimeInterval
    private let pingInterval: TimeInterval
    private let pongTimeout: TimeInterval
    private let networkStatus: @Sendable () -> String
    /// `nil` for every normal coaching session; only the explicit reconnect benchmark installs one.
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
    /// A server warned that this socket is going away, so the close and receive failure it produces
    /// next are the rotation itself rather than a fault. Cleared when the replacement opens.
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
        // `start` is always `.open(attempt: 1)`, and it is what makes a fresh session never-ready
        // again, so the short first-connect budget applies even on an instance that ran one before.
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

    /// Keep a healthy socket in place; the replacement credential is picked up if this stream later
    /// reconnects. This avoids destroying live transcript state merely because Settings saved a key.
    func updateAPIKey(_ apiKey: String) {
        lock.lock()
        self.apiKey = apiKey
        lock.unlock()
    }

    // MARK: - What the adapter may ask

    /// The socket that is ready to carry audio right now, or nil while none is.
    var readyLease: Lease? {
        lock.lock(); defer { lock.unlock() }
        guard let task, connected, !stopped else { return nil }
        return Lease(task: task, generation: generation)
    }

    /// Whether `lease` is still the installed socket. True from the moment it opens, so a frame that
    /// arrives before readiness is still attributed to the right socket.
    func isCurrent(_ lease: Lease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isCurrentLocked(lease)
    }

    /// Whether `lease` is installed and ready, so audio sent on it can be expected to land.
    func isReady(_ lease: Lease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isCurrentLocked(lease) && connected
    }

    /// Whether the socket of this generation is still installed, for callers that kept only the
    /// number. Generation alone identifies a socket: it is bumped on every open and on every stop.
    func isLive(generation candidate: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isLiveLocked(candidate)
    }

    /// Whether the socket of this generation is installed and ready.
    func isReady(generation candidate: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isLiveLocked(candidate) && connected
    }

    var currentGeneration: Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    /// Send on `lease`. A transport error retires the socket through the usual funnel; `completion`
    /// runs first with `false` so the adapter can release its own in-flight bookkeeping before the
    /// retirement asks for it back.
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

    /// The provider acknowledged the session configuration. An open socket alone is not readiness.
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

    /// The server warned that this socket is going away. Announce it once, then let the close or
    /// receive failure it produces next be read as the rotation it is.
    func noteExpectedRotation(_ lease: Lease, reason: String) {
        lock.lock()
        guard isCurrentLocked(lease), !rotationExpected else { lock.unlock(); return }
        rotationExpected = true
        lock.unlock()
        jlog("\(logPrefix): socket #\(lease.generation) rotating (\(reason))")
    }

    /// Replace a socket the server already warned is closing, ahead of the actual close. Spends no
    /// retry budget and reports nothing to the user: this is expected churn, not a fault.
    func requestRotation(_ lease: Lease, reason: String) {
        retire(lease, .expectedRotation(reason: reason))
    }

    /// Retire this socket with a cause the adapter classified itself, such as a local encoding fault
    /// or an in-band rejection a retry could still clear.
    func fail(_ lease: Lease, cause: ProviderFailure) {
        retire(lease, .failure(cause))
    }

    /// End a green-but-unusable stream immediately. `failure.disposition` must be `.permanent`: the
    /// policy terminates on those from any live phase, and answers `.ignore` only once something
    /// else has already ended this endpoint.
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

    /// Supplies the optional benchmark controller with the narrow fault operation. The controller,
    /// rather than normal capture state, owns whether a replacement connection is held.
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
        guard let adapter else { return }   // the stream is gone; there is nothing to connect for
        lock.lock(); let key = apiKey; lock.unlock()
        // NEVER log this request, its `.url`, or anything derived from it: Gemini authenticates with
        // a query parameter, so the key travels in the URL. `openDetail` is the safe form.
        let request = adapter.makeRequest(apiKey: key)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        lock.lock()
        let previousSession = self.session
        generation += 1
        let lease = Lease(task: task, generation: generation)
        self.session = session
        self.task = task
        connected = false
        pendingPingGeneration = nil
        // A fresh socket is not rotating anything, whether this is the first connect, a reconnect
        // after backoff, or the replacement a rotation just opened. Clearing it here keeps a genuine
        // failure of THIS socket on the budget-consuming path instead of being mistaken for the
        // churn its predecessor was warned about.
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
                // A failed pending receive is the EXPECTED artifact of an intentional stop
                // (cancel, then ENOTCONN / POSIX 57). Suppress it then; only a live failure retires.
                self.lock.lock()
                let isStopped = self.stopped
                let everReady = self.policy.everReady
                self.lock.unlock()
                if isStopped { return }
                guard let adapter = self.adapter else { return }
                // A refused upgrade (non-101) surfaces here as a transport error and the HTTP status
                // is on the task. Both vendors accept the upgrade even for a bad key and reject
                // afterwards, so a refused handshake is the edge itself refusing: region, VPN exit,
                // wrong URL. A permanent one ends the stream now instead of after the whole budget.
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
                // `retire` reads a failure on a socket already warned as going away as the rotation
                // it is, so there is nothing to check here.
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
        if isStopped { return }   // An intentional stop closes the socket on purpose.
        guard let adapter else { return }
        // A close code can be advance warning on its own: OpenAI's 1001 is a routine rotation we
        // reconnect through even when no in-band notice preceded it, since the two can arrive in
        // either order. Any other code stays visible.
        if adapter.isExpectedRotation(closeCode: closeCode.rawValue) {
            noteExpectedRotation(lease, reason: "server going away")
        }
        // `reason` is server-supplied content. It reaches Activity only through the failure record,
        // which redacts it, and is never logged verbatim.
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        let cause = adapter.classifyClose(code: closeCode.rawValue, reason: reasonText)
        // A permanent close skips the retry budget entirely: it is a provider-boundary failure a
        // retry cannot fix, the one case AGENTS.md permits exhausting a target immediately.
        if cause.disposition == .permanent {
            reportTerminalFailure(cause)
            return
        }
        retire(lease, .failure(cause))
    }

    // MARK: - Retiring a socket

    /// Move one socket out of service exactly once, then do whatever the policy says comes next.
    /// Every failure source (receive, close, send, readiness deadline, pong deadline, benchmark
    /// fault) and every rotation funnels through here; the lease guard prevents a late callback from
    /// an old socket from disrupting its healthy replacement.
    private func retire(_ lease: Lease, _ retirement: Retirement) {
        lock.lock()
        guard isCurrentLocked(lease), !terminalFailureReported else { lock.unlock(); return }
        var retirement = retirement
        // A failure on a socket the server already warned about is that warning coming true, not a
        // new fault, so it must not spend the budget a genuine failure will need.
        if case .failure(let cause) = retirement, rotationExpected {
            retirement = .expectedRotation(reason: cause.errorDescription ?? "socket failure")
        }
        let action: SocketLifecyclePolicy.Action
        switch retirement {
        case .failure(let cause): action = policy.failed(cause)
        case .expectedRotation: action = policy.expectedRotation()
        }
        connected = false
        pendingPingGeneration = nil
        // Remove the failed task immediately. A receive callback can pass `isCurrent` just before
        // this retirement wins the lock; `acknowledgeReady` checks the installed task again, so
        // clearing it prevents a late acknowledgement from resetting the budget or draining buffered
        // audio into the cancelled socket during the retry delay.
        let retiredSession = session
        task = nil
        session = nil
        if case .terminate = action { terminalFailureReported = true }
        lock.unlock()

        // The stream requeues whatever this socket never had acknowledged. It runs for a rotation
        // too: a replacement still has to replay the audio the retiring socket was carrying. Nothing
        // follows a termination, so its salvage happens in `connectionDidTerminate` instead.
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
            // Unreachable: `failed` and `expectedRotation` never answer either, and the lease guard
            // above already rejected the stopped and terminal phases that answer `.ignore`.
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
        // The benchmark can hold the replacement connection while synthetic audio fills the replay
        // buffer. Without one installed the path is identical.
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

    /// A retry delay is being waited out, so no socket is installed and none may be addressed.
    private var isBackingOffLocked: Bool {
        if case .backingOff = policy.phase { return true }
        return false
    }

    /// The socket is installed but has not been acknowledged yet, which is what the readiness
    /// deadline is waiting on.
    private func isPendingReadiness(_ lease: Lease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isCurrentLocked(lease) && !connected
    }

    /// Classify a transport error against this socket's readiness, which decides whether it reads as
    /// a connection that never came up or one lost after it was working.
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
