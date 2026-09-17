import Foundation

/// Design: wiki/lean-coaching-core.md
/// @unchecked Sendable: scheduler state is guarded by `stateLock`; the ledger, runner, and adapters
/// synchronize themselves.
public final class CoachDriver: @unchecked Sendable {
    public typealias AutomaticAttemptDelay =
        @Sendable (_ consecutiveAutomaticAttempt: Int) async throws -> Void

    private let transcriptionSettlement = TranscriptionSettlementGate()
    private let automaticAttemptDelay: AutomaticAttemptDelay
    private let coachingAttempts: (any CoachingAttemptAuditing)?
    private var _prepMaterial: (any PrepMaterialSearching)?
    private let ledger = CoachTranscriptLedger()
    private let transcript: RollingTranscript
    private var failedTranscriptBoundary: Int?
    private let runner: CoachAttemptRunner

    private let stateLock = NSLock()
    private let recoveryDelay: @Sendable (TimeInterval) async throws -> Void
    private let clock: Clock
    private var recovery = BrainCycleRecovery()
    private var recoveryDeadlineTask: Task<Void, Never>?
    private var sessionTerminated = false

    private var plan: SessionPlan
    private var routeRevision: UInt = 0
    /// Advances only on an explicit topology edit. Credential refreshes bump `routeRevision` alone,
    /// so they never supersede committed route health.
    private var routeTopologyRevision: UInt = 0
    private var configuredRoute: ConfiguredBrainRoute
    private var routeSession: BrainRouteSession
    /// Consumed when the next constructible target is selected, so an unavailable intermediate
    /// target is never announced as active.
    private var pendingTransitionOrigin: (target: BrainTarget, failure: ProviderFailure)?
    private var routeIsExhausted = false
    /// Delivery token for a committed exhaustion. Same-topology client refreshes keep it; an
    /// explicit replacement route clears it.
    private var exhaustionDeliveryGeneration: UInt = 0
    private var pendingExhaustionDeliveryGeneration: UInt?
    private var isHandling = false
    private var pendingTrigger: PendingTrigger?
    /// Lets the retry pause see a trigger that lands before its async waiter is installed.
    private var pendingTriggerGeneration: UInt = 0
    private var pendingTriggerWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// The turn-end's transcript boundary makes a delayed callback idempotent once another attempt
    /// has committed that speech.
    private struct PendingTrigger {
        let reason: TriggerReason
        let transcriptBoundary: Int?
    }

    struct AttemptBrain {
        let plan: SessionPlan
        let routeRevision: UInt
        let routeTopologyRevision: UInt
        let routeIndex: Int
        let target: BrainTarget
        let brain: BrainClient
        let summarizer: BrainClient?
        let onSelected: (@MainActor @Sendable (BrainTarget) -> Void)?
        let prepMaterial: (any PrepMaterialSearching)?
    }

    // Selection-step and delivery types stay module-visible so tests can drive the commit (callback
    // captured under `stateLock`) and the main-actor delivery as separate phases.
    struct RouteExhaustionDelivery {
        let generation: UInt
        let topologyRevision: UInt
        let target: BrainTarget
        let failure: ProviderFailure
        /// Captured at commit, so a later same-topology client refresh can neither redirect nor
        /// suppress this event.
        let callback: (@MainActor @Sendable (BrainTarget, ProviderFailure) -> Void)?
        var terminalCallback: (@MainActor @Sendable (BrainTarget, ProviderFailure) -> Void)? = nil
        var expiredCallback: (@MainActor @Sendable (ProviderFailure) -> Void)? = nil
    }

    struct RouteSkipDelivery {
        let topologyRevision: UInt
        let target: BrainTarget
        let failure: ProviderFailure
        let callback: (@MainActor @Sendable (BrainTarget, ProviderFailure) -> Void)?
    }

    struct RouteAdvanceDelivery {
        let topologyRevision: UInt
        let previous: BrainTarget
        let current: BrainTarget
        let failure: ProviderFailure
        let callback: (@MainActor @Sendable (BrainTarget, BrainTarget, ProviderFailure) -> Void)?
    }

    struct BrainSelectionStep {
        var selected: AttemptBrain? = nil
        var advanced: RouteAdvanceDelivery? = nil
        var skipped: RouteSkipDelivery? = nil
        var diagnostic: String? = nil
        var exhaustion: RouteExhaustionDelivery? = nil
        var alreadyExhausted = false
    }

    private let activity: (any ActivityEventRecording)?

    public init(
        config: Config,
        transcript: RollingTranscript,
        route: ConfiguredBrainRoute,
        screen: ScreenCapturing,
        overlay: OverlayRendering,
        clock: Clock,
        sessionStart: TimeInterval? = nil,
        coachingAttempts: (any CoachingAttemptAuditing)? = nil,
        plan: SessionPlan = .default,
        automaticAttemptDelay: AutomaticAttemptDelay? = nil,
        recoveryDelay: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        activity: (any ActivityEventRecording)? = nil,
        capabilities: CoachCapabilities = .default,
        prepMaterial: (any PrepMaterialSearching)? = nil
    ) {
        self.recoveryDelay = recoveryDelay
        self.clock = clock
        self.plan = plan
        self.activity = activity
        self._prepMaterial = prepMaterial
        self.transcript = transcript
        self.configuredRoute = route
        self.routeSession = BrainRouteSession(targetCount: route.targets.count)
        self.coachingAttempts = coachingAttempts
        self.automaticAttemptDelay = automaticAttemptDelay ?? Self.defaultAutomaticAttemptDelay
        self.runner = CoachAttemptRunner(
            config: config,
            transcript: transcript,
            screen: screen,
            overlay: overlay,
            clock: clock,
            sessionStart: sessionStart ?? clock.now(),
            coachingAttempts: coachingAttempts,
            activity: activity,
            ledger: ledger,
            capabilities: capabilities)
    }

    private static let defaultAutomaticAttemptDelay: AutomaticAttemptDelay = { _ in
        try await Task.sleep(for: .milliseconds(500))
    }

    /// Takes effect at the next attempt; an attempt in flight keeps the plan it snapshotted.
    public func updatePlan(_ plan: SessionPlan) {
        stateLock.lock()
        self.plan = SessionPlan(revision: plan.revision, screen: plan.screen)
        stateLock.unlock()
    }

    /// Takes effect at the next attempt. Nothing waits for it; a search before then finds no notes.
    public func installPrepMaterial(_ port: (any PrepMaterialSearching)?) {
        stateLock.lock()
        _prepMaterial = port
        stateLock.unlock()
    }

    /// Installs a new route topology for the next attempt and resets route health.
    public func updateBrainRoute(_ route: ConfiguredBrainRoute) {
        stateLock.lock()
        routeRevision &+= 1
        routeTopologyRevision &+= 1
        configuredRoute = route
        routeSession = BrainRouteSession(targetCount: route.targets.count)
        failedTranscriptBoundary = nil
        pendingTransitionOrigin = nil
        routeIsExhausted = false
        pendingExhaustionDeliveryGeneration = nil
        stateLock.unlock()
    }

    /// Swaps clients for `providers` (all when nil), keeping route health. A refreshed in-flight
    /// attempt's failure is ignored but its success counts. Returns false if the targets differ.
    @discardableResult
    public func refreshBrainRouteClients(
        _ route: ConfiguredBrainRoute,
        for providers: Set<BrainProvider>? = nil
    ) -> Bool {
        stateLock.lock()
        guard configuredRoute.targets.map(\.target) == route.targets.map(\.target) else {
            stateLock.unlock()
            return false
        }
        let refreshesActiveTarget = providers.map {
            $0.contains(configuredRoute.targets[routeSession.activeIndex].target.provider)
        } ?? true
        if refreshesActiveTarget {
            routeRevision &+= 1
        }
        let targets = zip(configuredRoute.targets, route.targets).map { pair in
            let (current, replacement) = pair
            let shouldReplace = providers.map {
                $0.contains(replacement.target.provider)
            } ?? true
            guard shouldReplace else {
                return current
            }
            return replacement
        }
        configuredRoute = ConfiguredBrainRoute(
            targets: targets,
            onSelected: route.onSelected,
            onAdvanced: route.onAdvanced,
            onSkipped: route.onSkipped,
            onRecoveryChanged: route.onRecoveryChanged,
            onExhausted: route.onExhausted,
            onTerminated: route.onTerminated,
            onRecoveryExpired: route.onRecoveryExpired)
        let activeReplacement = refreshesActiveTarget && !routeIsExhausted
            ? configuredRoute.targets[routeSession.activeIndex]
            : nil
        stateLock.unlock()
        activeReplacement?.prepare()
        return true
    }

    /// Swaps clients for a non-topology edit (e.g. reasoning effort). The in-flight attempt stays
    /// valid and its result counts normally. Returns false if the targets differ.
    @discardableResult
    public func reconfigureBrainRouteClients(_ route: ConfiguredBrainRoute) -> Bool {
        stateLock.lock()
        guard configuredRoute.targets.map(\.target) == route.targets.map(\.target) else {
            stateLock.unlock()
            return false
        }
        let targets = route.targets
        configuredRoute = ConfiguredBrainRoute(
            targets: targets,
            onSelected: route.onSelected,
            onAdvanced: route.onAdvanced,
            onSkipped: route.onSkipped,
            onRecoveryChanged: route.onRecoveryChanged,
            onExhausted: route.onExhausted,
            onTerminated: route.onTerminated,
            onRecoveryExpired: route.onRecoveryExpired)
        let activeReplacement = routeIsExhausted
            ? nil
            : configuredRoute.targets[routeSession.activeIndex]
        stateLock.unlock()
        activeReplacement?.prepare()
        return true
    }

    /// Returns the cancelled compaction task so teardown can drain it before sealing the audit.
    @discardableResult
    public func cancelBackgroundWork() -> Task<Void, Never>? {
        stateLock.withLock { recoveryDeadlineTask?.cancel(); recoveryDeadlineTask = nil }
        return runner.cancelBackgroundWork()
    }

    /// `hasPendingWork` means the provider still owns speech or transcript work, not merely that
    /// the audio is non-silent.
    public func updateTranscriptionWork(_ hasPendingWork: Bool, for speaker: Speaker) {
        transcriptionSettlement.setUnsettled(hasPendingWork, for: speaker)
    }

    private func waitForTranscriptionSettlement(
        before work: CoachAttemptRunner.PendingCoachingWork
    ) async -> CoachAttemptRunner.PendingCoachingWork {
        guard !work.bypassesTranscriptionSettlement else { return work }

        let interruptGeneration = transcriptionSettlement.interruptGenerationSnapshot()
        var settledWork = work
        var receivedTrigger = false
        var wake = takePendingTriggerSnapshot()
        if let pending = wake.trigger?.reason {
            receivedTrigger = true
            settledWork.reason = Self.coalescing(settledWork.reason, with: pending)
            settledWork.bypassesTranscriptionSettlement = pending.isManual
        }
        guard !settledWork.bypassesTranscriptionSettlement else {
            settledWork.wake = .trigger
            return settledWork
        }

        await transcriptionSettlement.waitUntilSettled(
            unlessInterruptedAfter: interruptGeneration)
        wake = takePendingTriggerSnapshot()
        if let pending = wake.trigger?.reason {
            receivedTrigger = true
            settledWork.reason = Self.coalescing(settledWork.reason, with: pending)
            settledWork.bypassesTranscriptionSettlement = pending.isManual
        }
        if receivedTrigger {
            settledWork.wake = .trigger
        }
        return settledWork
    }

    private enum TriggerClaim {
        case claimed
        case pending
        case covered
        case exhausted
    }

    private func claimOrPend(_ trigger: PendingTrigger) -> TriggerClaim {
        let waiters: [CheckedContinuation<Void, Never>]
        stateLock.lock()
        if sessionTerminated { stateLock.unlock(); return .exhausted }
        if routeIsExhausted && !isHandling &&
            !trigger.reason.isManual && transcript.count <= (failedTranscriptBoundary ?? transcript.count) {
            stateLock.unlock()
            return .exhausted
        }
        if isCoveredByCommittedTranscript(trigger) {
            stateLock.unlock()
            return .covered
        }
        if isHandling {
            pendingTrigger = Self.coalescing(pendingTrigger, with: trigger)
            pendingTriggerGeneration &+= 1
            waiters = Array(pendingTriggerWaiters.values)
            pendingTriggerWaiters.removeAll()
            stateLock.unlock()
            waiters.forEach { $0.resume() }
            if trigger.reason.isManual {
                // Wake an automatic attempt parked on unsettled speech; the trigger stays queued.
                transcriptionSettlement.interruptWaiters()
            }
            return .pending
        }
        // Fallback selection stays sticky; only a fully exhausted route restarts at the primary.
        if routeIsExhausted {
            routeSession = BrainRouteSession(targetCount: configuredRoute.targets.count)
            routeIsExhausted = false
            pendingTransitionOrigin = nil
            pendingExhaustionDeliveryGeneration = nil
            failedTranscriptBoundary = nil
        } else {
            routeSession.recordSuccess()
            failedTranscriptBoundary = nil
        }
        isHandling = true
        stateLock.unlock()
        return .claimed
    }

    private static func coalescing(
        _ existing: TriggerReason?,
        with incoming: TriggerReason
    ) -> TriggerReason {
        if incoming.isManual { return incoming }
        if let existing, existing.isManual { return existing }
        return incoming
    }

    private static func coalescing(
        _ existing: PendingTrigger?,
        with incoming: PendingTrigger
    ) -> PendingTrigger {
        guard let existing else { return incoming }
        let reason = coalescing(existing.reason, with: incoming.reason)
        let boundary: Int?
        if reason == .turnEnd {
            let turnEnds = [existing, incoming].filter { $0.reason == .turnEnd }
            // A turn-end without a boundary can't be proven covered, so the merge keeps no
            // boundary.
            boundary = turnEnds.allSatisfy { $0.transcriptBoundary != nil }
                ? turnEnds.compactMap(\.transcriptBoundary).max()
                : nil
        } else {
            boundary = nil
        }
        return PendingTrigger(reason: reason, transcriptBoundary: boundary)
    }

    /// Must be called while `stateLock` is held. The ledger is a leaf: it never takes this lock.
    private func isCoveredByCommittedTranscript(_ trigger: PendingTrigger) -> Bool {
        trigger.reason == .turnEnd
            && trigger.transcriptBoundary.map { $0 <= ledger.committedCount } == true
    }

    /// Takes trigger and generation in one step, so a trigger landing before the waiter registers
    /// still wakes it.
    private func takePendingTriggerSnapshot() -> (trigger: PendingTrigger?, generation: UInt) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let pending = pendingTrigger.flatMap {
            isCoveredByCommittedTranscript($0) ? nil : $0
        }
        pendingTrigger = nil
        return (pending, pendingTriggerGeneration)
    }

    private func waitForPendingTrigger(after generation: UInt) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                stateLock.lock()
                if Task.isCancelled || pendingTriggerGeneration != generation {
                    stateLock.unlock()
                    continuation.resume()
                } else {
                    pendingTriggerWaiters[id] = continuation
                    stateLock.unlock()
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Never>?
            self.stateLock.lock()
            continuation = self.pendingTriggerWaiters.removeValue(forKey: id)
            self.stateLock.unlock()
            continuation?.resume()
        }
    }

    private func waitForAutomaticWakeOrDelay(
        sequence: Int,
        after generation: UInt
    ) async {
        await withTaskGroup(of: Void.self) { group in
            let delay = automaticAttemptDelay
            group.addTask {
                try? await delay(sequence)
            }
            group.addTask {
                await self.waitForPendingTrigger(after: generation)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// Take-or-release is one locked step, so a trigger arriving at completion is never orphaned.
    private func finishOrTakeNextTrigger() -> PendingTrigger? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let pendingTrigger {
            self.pendingTrigger = nil
            if !isCoveredByCommittedTranscript(pendingTrigger) {
                routeSession.recordSuccess()
                failedTranscriptBoundary = nil
                return pendingTrigger
            }
        }
        isHandling = false
        return nil
    }

    /// Only input the failed attempt did not include may start another cycle immediately.
    private func finishFailedCycle(unattemptedManualReason: TriggerReason? = nil) -> TriggerReason? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let next = pendingTrigger
        pendingTrigger = nil
        if !Task.isCancelled && !sessionTerminated && (unattemptedManualReason != nil || next?.reason.isManual == true ||
            transcript.count > (failedTranscriptBoundary ?? transcript.count)) {
            routeSession = BrainRouteSession(targetCount: configuredRoute.targets.count)
            routeIsExhausted = false
            pendingTransitionOrigin = nil
            pendingExhaustionDeliveryGeneration = nil
            failedTranscriptBoundary = nil
            if let next { return Self.coalescing(unattemptedManualReason, with: next.reason) }
            return unattemptedManualReason ?? .turnEnd
        }
        isHandling = false
        return nil
    }

    private func releaseHandlingSlot() {
        stateLock.lock()
        isHandling = false
        if routeIsExhausted {
            pendingTrigger = nil
        }
        stateLock.unlock()
    }

    private func selectBrainForAttempt() async -> AttemptBrain? {
        while true {
            let step = takeBrainSelectionStep()
            if step.alreadyExhausted {
                return nil
            }
            if let diagnostic = step.diagnostic {
                jlog(diagnostic)
            }
            if let skipped = step.skipped {
                await deliverRouteSkip(skipped)
            }
            if let advanced = step.advanced {
                await deliverRouteAdvance(advanced)
            }
            if let exhausted = step.exhaustion {
                if await deliverRouteExhaustion(exhausted) {
                    return nil
                }
                continue
            }
            if let selected = step.selected {
                guard await deliverRouteSelection(selected) else {
                    continue
                }
                return selected
            }
        }
    }

    func takeBrainSelectionStep() -> BrainSelectionStep {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !routeIsExhausted, !sessionTerminated else {
            return BrainSelectionStep(alreadyExhausted: true)
        }

        var step = BrainSelectionStep()
        let index = routeSession.activeIndex
        let configured = configuredRoute.targets[index]
        if let brain = configured.brain, recovery.permanentFailures[configured.target] == nil {
            if let origin = pendingTransitionOrigin {
                step.advanced = RouteAdvanceDelivery(
                    topologyRevision: routeTopologyRevision,
                    previous: origin.target,
                    current: configured.target,
                    failure: origin.failure,
                    callback: configuredRoute.onAdvanced)
                pendingTransitionOrigin = nil
            }
            step.selected = AttemptBrain(
                plan: plan,
                routeRevision: routeRevision,
                routeTopologyRevision: routeTopologyRevision,
                routeIndex: index,
                target: configured.target,
                brain: brain,
                summarizer: configured.summarizer,
                onSelected: configuredRoute.onSelected,
                prepMaterial: _prepMaterial)
            return step
        }

        let failure = recovery.permanentFailures[configured.target] ?? configured.unavailability
            ?? ProviderFailure(
                source: .brain(configured.target.provider), stage: .process,
                category: .unavailable, disposition: .permanent, identity: .init(),
                message: "\(configured.target.provider.displayName) is unavailable")
        if failure.disposition == .permanent { recovery.markPermanent(configured.target, failure: failure) }
        step.diagnostic = "Jarvis coach: skipping unavailable route target "
            + "\(configured.target.provider.displayName): \(failure.errorDescription ?? "")"
        step.skipped = RouteSkipDelivery(
            topologyRevision: routeTopologyRevision,
            target: configured.target,
            failure: failure,
            callback: configuredRoute.onSkipped)
        if pendingTransitionOrigin == nil {
            pendingTransitionOrigin = (configured.target, failure)
        }
        switch routeSession.skipUnavailable() {
        case .advanced:
            break
        case .exhausted:
            routeIsExhausted = true
            failedTranscriptBoundary = failedTranscriptBoundary ?? transcript.count
            exhaustionDeliveryGeneration &+= 1
            pendingExhaustionDeliveryGeneration = exhaustionDeliveryGeneration
            step.exhaustion = RouteExhaustionDelivery(
                generation: exhaustionDeliveryGeneration,
                topologyRevision: routeTopologyRevision,
                target: configured.target,
                failure: failure,
                callback: configuredRoute.onExhausted,
                terminalCallback: configuredRoute.onTerminated,
                expiredCallback: configuredRoute.onRecoveryExpired)
        case .stay:
            preconditionFailure("skipping an unavailable target cannot stay")
        }
        return step
    }

    private enum RouteFailureAction {
        case retry(failureCount: Int, advanced: Bool)
        case staleRevision
        case exhausted
    }

    private func recordAttemptFailure(
        _ failure: ProviderFailure,
        on attempt: AttemptBrain,
        transcriptBoundary: Int
    ) async -> RouteFailureAction {
        let record = applyAttemptFailure(failure, on: attempt, transcriptBoundary: transcriptBoundary)
        if let exhaustion = record.exhaustion {
            return await deliverRouteExhaustion(exhaustion)
                ? record.action
                : .staleRevision
        }
        return record.action
    }

    private func applyAttemptFailure(
        _ failure: ProviderFailure,
        on attempt: AttemptBrain,
        transcriptBoundary: Int
    ) -> (
        action: RouteFailureAction,
        exhaustion: RouteExhaustionDelivery?
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if routeRevision != attempt.routeRevision
            || routeSession.activeIndex != attempt.routeIndex {
            return (.staleRevision, nil)
        }

        failedTranscriptBoundary = transcriptBoundary
        if failure.disposition == .permanent { recovery.markPermanent(attempt.target, failure: failure) }
        switch routeSession.recordFailure(failure.disposition) {
        case .stay(let count):
            return (.retry(failureCount: count, advanced: false), nil)
        case .advanced:
            pendingTransitionOrigin = (attempt.target, failure)
            return (
                .retry(
                    failureCount: BrainRouteSession.failuresPerTarget,
                    advanced: true),
                nil)
        case .exhausted:
            routeIsExhausted = true
            failedTranscriptBoundary = transcriptBoundary
            exhaustionDeliveryGeneration &+= 1
            pendingExhaustionDeliveryGeneration = exhaustionDeliveryGeneration
            return (
                .exhausted,
                RouteExhaustionDelivery(
                    generation: exhaustionDeliveryGeneration,
                    topologyRevision: routeTopologyRevision,
                    target: attempt.target,
                    failure: failure,
                    callback: configuredRoute.onExhausted,
                terminalCallback: configuredRoute.onTerminated,
                expiredCallback: configuredRoute.onRecoveryExpired))
        }
    }

    private func recordAttemptSuccess(on attempt: AttemptBrain) {
        stateLock.lock()
        // Recovery counts success on any topology; cursor health only on the attempt's own.
        recovery.succeed()
        recoveryDeadlineTask?.cancel()
        recoveryDeadlineTask = nil
        if routeTopologyRevision == attempt.routeTopologyRevision
            && routeSession.activeIndex == attempt.routeIndex {
            routeSession.recordSuccess()
            failedTranscriptBoundary = nil
        }
        stateLock.unlock()
    }

    private func reportBrainRecovery(_ provider: BrainProvider?, on attempt: AttemptBrain) async {
        await MainActor.run {
            let callback = stateLock.withLock {
                guard !Task.isCancelled, !sessionTerminated,
                      provider == nil || (routeRevision == attempt.routeRevision
                        && routeSession.activeIndex == attempt.routeIndex) else {
                    return Optional<(@MainActor @Sendable (BrainProvider?) -> Void)>.none
                }
                return configuredRoute.onRecoveryChanged
            }
            callback?(provider)
        }
    }

    /// Delivers at most once per generation token; an explicit route update clears the token first.
    private func deliverRouteExhaustion(_ delivery: RouteExhaustionDelivery) async -> Bool {
        await MainActor.run {
            stateLock.lock()
            let shouldDeliver = routeIsExhausted
                && pendingExhaustionDeliveryGeneration == delivery.generation
            if shouldDeliver {
                pendingExhaustionDeliveryGeneration = nil
            }
            stateLock.unlock()
            guard shouldDeliver else {
                jlog("Jarvis coach: ignoring route exhaustion from a superseded Settings revision")
                return false
            }
            let health = stateLock.withLock { () -> (allPermanent: Bool, expired: Bool, remaining: TimeInterval) in
                recovery.fail(at: clock.now(), failure: delivery.failure)
                let allPermanent = configuredRoute.targets.allSatisfy {
                    recovery.permanentFailures[$0.target] != nil
                }
                let expired = recovery.ceilingReached(at: clock.now())
                sessionTerminated = allPermanent || expired
                return (allPermanent, expired, recovery.remainingBeforeCeiling(at: clock.now()))
            }
            if health.allPermanent {
                delivery.terminalCallback?(delivery.target, delivery.failure)
            } else if health.expired {
                delivery.expiredCallback?(delivery.failure)
            } else {
                activity?.record(.coachingCycleFailed(failure: delivery.failure))
                delivery.callback?(delivery.target, delivery.failure)
                stateLock.withLock {
                    if recoveryDeadlineTask == nil {
                        recoveryDeadlineTask = makeRecoveryDeadlineTask(after: health.remaining)
                    }
                }
            }

            // A callback may synchronously install a replacement route, which supersedes teardown.
            stateLock.lock()
            let remainsTerminal = routeIsExhausted
                && routeTopologyRevision == delivery.topologyRevision
            stateLock.unlock()
            return remainsTerminal
        }
    }

    // Weak self while sleeping; cancelled explicitly on success and teardown. Building this task
    // inline in the nested MainActor delivery closure hits a Swift 6.3 task-allocation trap.
    private func makeRecoveryDeadlineTask(after seconds: TimeInterval) -> Task<Void, Never> {
        let delay = recoveryDelay
        return Task.detached { [weak self] in
            do { try await delay(seconds) } catch { return }
            guard !Task.isCancelled, let self else { return }
            await self.terminateExpiredRecovery()
        }
    }

    /// Reads the streak's latest failure at fire time, not the one the task was created with.
    private func terminateExpiredRecovery() async {
        await MainActor.run {
            let expiry = stateLock.withLock {
                () -> (callback: (@MainActor @Sendable (ProviderFailure) -> Void)?, failure: ProviderFailure)? in
                guard !Task.isCancelled, !sessionTerminated, let streak = recovery.streak,
                      recovery.ceilingReached(at: clock.now()) else { return nil }
                sessionTerminated = true
                return (configuredRoute.onRecoveryExpired, streak.lastFailure)
            }
            guard let expiry else { return }
            expiry.callback?(expiry.failure)
        }
    }

    private func waitForCycleCooldown() async -> Bool {
        let delay = stateLock.withLock { max(0, recovery.nextCycleAt - clock.now()) }
        do { if delay > 0 { try await recoveryDelay(delay) } }
        catch { return false }
        return stateLock.withLock { !sessionTerminated } && !Task.isCancelled
    }

    private func isCurrentRouteRevision(_ revision: UInt) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return routeRevision == revision
    }

    private func isCurrentRouteTopologyRevision(_ revision: UInt) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return routeTopologyRevision == revision
    }

    private func deliverRouteSelection(_ attempt: AttemptBrain) async -> Bool {
        await MainActor.run {
            guard isCurrentRouteRevision(attempt.routeRevision) else {
                jlog("Jarvis coach: ignoring target selection from a superseded Settings revision")
                return false
            }
            attempt.onSelected?(attempt.target)
            return true
        }
    }

    func deliverRouteSkip(_ delivery: RouteSkipDelivery) async {
        guard let callback = delivery.callback else { return }
        await MainActor.run {
            guard isCurrentRouteTopologyRevision(delivery.topologyRevision) else {
                jlog("Jarvis coach: ignoring target skip from a superseded Settings revision")
                return
            }
            callback(delivery.target, delivery.failure)
        }
    }

    func deliverRouteAdvance(_ delivery: RouteAdvanceDelivery) async {
        guard let callback = delivery.callback else { return }
        await MainActor.run {
            guard isCurrentRouteTopologyRevision(delivery.topologyRevision) else {
                jlog("Jarvis coach: ignoring route transition from a superseded Settings revision")
                return
            }
            callback(delivery.previous, delivery.current, delivery.failure)
        }
    }

    @discardableResult
    public func handleTrigger(
        _ reason: TriggerReason,
        transcriptBoundary: Int? = nil
    ) async -> TurnOutcome {
        let trigger = PendingTrigger(
            reason: reason,
            transcriptBoundary: reason == .turnEnd ? transcriptBoundary : nil)
        switch claimOrPend(trigger) {
        case .claimed:
            break
        case .pending:
            jlog("… busy; batching this \(reason) into the pending conversation")
            return .busy
        case .covered:
            jlog("… coalesced deferred turn for already-committed transcript")
            return .busy
        case .exhausted:
            jlog("… cycle failed; waiting for new input")
            return .brainError
        }

        var work = CoachAttemptRunner.PendingCoachingWork(reason: reason)
        var automaticSequence = 0
        var unattemptedManualReason: TriggerReason?
        var latestOutcome: TurnOutcome = .silentByModel

        while !Task.isCancelled {
            guard await waitForCycleCooldown() else { releaseHandlingSlot(); return .cancelled }
            work = await waitForTranscriptionSettlement(before: work)
            if Task.isCancelled {
                releaseHandlingSlot()
                return .cancelled
            }
            guard let attempt = await selectBrainForAttempt() else {
                if let next = finishFailedCycle(unattemptedManualReason: unattemptedManualReason) {
                    unattemptedManualReason = nil
                    work = CoachAttemptRunner.PendingCoachingWork(reason: next)
                    automaticSequence = 0
                    continue
                }
                return .brainError
            }

            unattemptedManualReason = nil
            let execution = await runner.runAttempt(work, using: attempt)
            switch execution.result {
            case .completed(let outcome):
                latestOutcome = outcome
                recordAttemptSuccess(on: attempt)
                await reportBrainRecovery(nil, on: attempt)
                if let id = execution.id {
                    let terminal: CoachingAttemptAuditEvent.TerminalAction = outcome == .spoke
                        ? .speak
                        : .staySilent
                    coachingAttempts?.recordFinished(
                        attemptID: id, terminal: terminal, outcome: outcome)
                }
                automaticSequence = 0
                guard let next = finishOrTakeNextTrigger() else {
                    return latestOutcome
                }
                work = CoachAttemptRunner.PendingCoachingWork(reason: next.reason)

            case .skipped(let outcome):
                latestOutcome = outcome
                if let id = execution.id {
                    coachingAttempts?.recordFinished(
                        attemptID: id, terminal: .skippedFiller, outcome: outcome)
                }
                guard let next = finishOrTakeNextTrigger() else {
                    return latestOutcome
                }
                work = CoachAttemptRunner.PendingCoachingWork(reason: next.reason)

            case .cancelled:
                if let id = execution.id {
                    coachingAttempts?.recordFinished(
                        attemptID: id, terminal: .cancelled, outcome: .cancelled)
                }
                releaseHandlingSlot()
                return .cancelled

            case .failed(let outcome, let failure, var failedWork):
                latestOutcome = outcome
                let action = await recordAttemptFailure(failure, on: attempt,
                    transcriptBoundary: failedWork.attemptedTranscriptBoundary)
                if let id = execution.id {
                    let terminal: CoachingAttemptAuditEvent.TerminalAction
                    switch action {
                    case .exhausted:
                        terminal = .exhaustion
                    case .retry, .staleRevision:
                        terminal = .failure
                    }
                    coachingAttempts?.recordFinished(
                        attemptID: id,
                        terminal: terminal,
                        outcome: outcome)
                }
                let routeChanged: Bool
                switch action {
                case .exhausted:
                    if let next = finishFailedCycle() {
                        work = CoachAttemptRunner.PendingCoachingWork(reason: next)
                        automaticSequence = 0
                        continue
                    }
                    return .brainError
                case .staleRevision:
                    routeChanged = true
                    jlog("Jarvis coach: preserving pending work from superseded route revision")
                case .retry(let failureCount, let advanced):
                    routeChanged = false
                    if !advanced {
                        await reportBrainRecovery(attempt.target.provider, on: attempt)
                    }
                    let policy = failure.disposition == .permanent
                        ? "permanent failure"
                        : "temporary/unknown failure \(failureCount)"
                    let routeAction = advanced ? "; next fresh attempt advances the route" : ""
                    jlog("Jarvis coach: \(attempt.target.provider.displayName) \(policy)\(routeAction)")
                }

                var wake = takePendingTriggerSnapshot()
                var receivedTrigger = wake.trigger != nil
                var explicitManualWake = wake.trigger?.reason.isManual == true
                if let reason = wake.trigger?.reason {
                    failedWork.reason = Self.coalescing(failedWork.reason, with: reason)
                }
                work = failedWork
                automaticSequence += 1

                // Without a natural wake, a bounded delay keeps a quiet outage from spinning.
                if wake.trigger == nil && !routeChanged {
                    await waitForAutomaticWakeOrDelay(
                        sequence: automaticSequence,
                        after: wake.generation)
                }
                if Task.isCancelled {
                    releaseHandlingSlot()
                    return .cancelled
                }

                // Consume a trigger that arrived during the delay here, so a shortcut keeps its
                // manual semantics (no settlement wait) at the admission boundary.
                wake = takePendingTriggerSnapshot()
                if let reason = wake.trigger?.reason {
                    receivedTrigger = true
                    explicitManualWake = explicitManualWake || reason.isManual
                    work.reason = Self.coalescing(work.reason, with: reason)
                }
                work.bypassesTranscriptionSettlement = explicitManualWake
                unattemptedManualReason = explicitManualWake ? work.reason : nil
                work.wake = receivedTrigger ? .trigger : .pendingWork
            }
        }

        releaseHandlingSlot()
        return .cancelled
    }

}

public enum TurnOutcome: Sendable, Equatable {
    case spoke
    case silentByModel
    case skippedFillerOnly
    case truncated
    case busy
    case cancelled
    case brainError
    case exhausted
}
