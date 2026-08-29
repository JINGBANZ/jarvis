import Foundation

/// The single-flight coaching scheduler, and the session's public face.
///
/// A coaching attempt snapshots exactly one route target and owns that target for its complete tool
/// loop. Failed provider requests are never replayed inside the attempt. Instead, failed conversation
/// work stays uncommitted and this scheduler starts a fresh attempt from the latest finalized
/// transcript plus provider-neutral observations completed earlier.
///
/// The state-ownership boundary with `CoachAttemptRunner`, which executes those attempts
/// (wiki/lean-coaching-core.md, Phase 5):
///
/// - **This type owns** trigger coalescing and pending-trigger generations, transcription
///   settlement, the single-flight handling slot, and forward-only route state — selection,
///   advance, skip, exhaustion, and the delivery tokens that make a terminal transition land
///   exactly once. All of it lives under this type's one `stateLock`.
/// - **The runner owns** one attempt's execution: filler classification, the bounded tool loop, the
///   `capture_screen` continuation, overlay delivery, history commit, off-path compaction, and
///   attempt identity.
///
/// The interface is one call per attempt — an immutable `AttemptBrain` plus the pending work in, an
/// `AttemptExecution` out — over the shared `CoachTranscriptLedger`, which is the single datum both
/// halves read: the committed transcript boundary that makes a late turn-end idempotent. Nothing
/// new coordinates between them.
///
/// `@unchecked Sendable` is justified because mutable scheduler state is guarded by `stateLock`;
/// the ledger, the runner, and injected adapters are independently synchronized.
public final class CoachDriver: @unchecked Sendable {
    public typealias AutomaticAttemptDelay =
        @Sendable (_ consecutiveAutomaticAttempt: Int) async throws -> Void

    private let transcriptionSettlement = TranscriptionSettlementGate()
    private let automaticAttemptDelay: AutomaticAttemptDelay
    private let coachingAttempts: (any CoachingAttemptAuditing)?
    /// The committed transcript boundary shared with the runner. It only grows, so reading it
    /// inside this type's lock needs no coordination with the runner's.
    private let ledger = CoachTranscriptLedger()
    /// The attempt half. One per driver, so history and the compaction lifetime match the session's.
    private let runner: CoachAttemptRunner

    private let stateLock = NSLock()
    /// The control-plane snapshot new attempts run against. Installed at Start and at explicit
    /// between-attempt boundaries only; an attempt keeps the revision it snapshotted for its whole
    /// tool loop, so a Settings edit can never change what a turn already started doing.
    private var plan: SessionPlan
    private var routeRevision: UInt = 0
    /// Advances only when an explicit Settings edit replaces route topology. Credential refreshes
    /// use `routeRevision` for stale attempt gating but must not supersede committed route health.
    private var routeTopologyRevision: UInt = 0
    private var configuredRoute: ConfiguredBrainRoute
    private var routeSession: BrainRouteSession
    /// Set after a target exhausts, then consumed when the next constructible target is selected.
    /// This avoids announcing an unavailable intermediate target as active.
    private var pendingTransitionOrigin: BrainTarget?
    private var routeIsExhausted = false
    /// A committed terminal transition owns one delivery token independent of client revisions.
    /// Same-topology client changes preserve it; an explicit replacement route clears it.
    private var exhaustionDeliveryGeneration: UInt = 0
    private var pendingExhaustionDeliveryGeneration: UInt?
    private var isHandling = false
    /// Natural triggers coalesce while an attempt or automatic pending-work wait owns the slot.
    private var pendingTrigger: PendingTrigger?
    /// Monotonic pulse used to race bounded automatic backoff against a newly coalesced trigger
    /// without losing a trigger that lands just before the async waiter is installed.
    private var pendingTriggerGeneration: UInt = 0
    private var pendingTriggerWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// A turn-end carries the transcript boundary that caused it. This makes a delayed callback
    /// idempotent after another admitted attempt already committed the same finalized speech.
    private struct PendingTrigger {
        let reason: TriggerReason
        let transcriptBoundary: Int?
    }

    // Module-visible only because `BrainSelectionStep` carries one; see the note on the route
    // delivery types below.
    struct AttemptBrain {
        /// Frozen with the target: every capture in this attempt, including a `capture_screen`
        /// continuation, runs against this one revision.
        let plan: SessionPlan
        let routeRevision: UInt
        let routeTopologyRevision: UInt
        let routeIndex: Int
        let target: BrainTarget
        let brain: BrainClient
        let summarizer: BrainClient?
        let onSelected: (@MainActor @Sendable (BrainTarget) -> Void)?
    }




    // Module-visible only because `BrainSelectionStep` carries one; see the note below.
    struct RouteExhaustionDelivery {
        let generation: UInt
        let topologyRevision: UInt
        let target: BrainTarget
        let failure: BrainFailure
        /// Captured when exhaustion commits. A later same-topology client refresh must neither
        /// redirect the already-committed event to a second callback nor suppress this one.
        let callback: (@MainActor @Sendable (BrainTarget, BrainFailure) -> Void)?
    }

    // Committing a route notice and delivering it are deliberately separate phases: the commit
    // captures the callback under `stateLock`, and the delivery replays that captured callback
    // after crossing to the main actor, so a client refresh in between can neither drop nor
    // redirect it. The two phases and their delivery types are module-visible rather than private
    // so a test can drive them in sequence. Through the public async API they are adjacent within
    // one task with nothing observable in between, which leaves a test only able to guess when the
    // commit landed — a race that no amount of waiting closes.

    /// A route-health notice committed under the lock and consumed once after crossing to the main
    /// actor. Client-only refreshes preserve it; an explicit topology edit supersedes it.
    struct RouteSkipDelivery {
        let topologyRevision: UInt
        let target: BrainTarget
        let callback: (@MainActor @Sendable (BrainTarget) -> Void)?
    }

    /// The paired target transition committed when the next constructible target is selected.
    struct RouteAdvanceDelivery {
        let topologyRevision: UInt
        let previous: BrainTarget
        let current: BrainTarget
        let callback: (@MainActor @Sendable (BrainTarget, BrainTarget) -> Void)?
    }

    struct BrainSelectionStep {
        var selected: AttemptBrain? = nil
        var advanced: RouteAdvanceDelivery? = nil
        var skipped: RouteSkipDelivery? = nil
        var diagnostic: String? = nil
        var exhaustion: RouteExhaustionDelivery? = nil
        var alreadyExhausted = false
    }

    /// The human-facing evidence port. The kernel names only the port and the closed
    /// `ActivityEvent` vocabulary; the concrete persistence behind it is composed at the App edge
    /// (wiki/lean-coaching-core.md, Phase 2). Absent means this session shows no Activity — which,
    /// like every other optional-evidence state, cannot change a coaching outcome.
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
        activity: (any ActivityEventRecording)? = nil
    ) {
        self.plan = plan
        self.activity = activity
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
            ledger: ledger)
    }

    private static let defaultAutomaticAttemptDelay: AutomaticAttemptDelay = { sequence in
        let seconds = min(0.5 * pow(2, Double(max(0, sequence - 1))), 4)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Install a fresh control-plane revision for the next attempt. This is the declared
    /// between-attempt boundary: an attempt already running keeps the revision it snapshotted, so a
    /// Settings edit never takes effect mid-turn. Runtime health never calls this — only an explicit
    /// user edit does, and it never rewrites the persisted preference either.
    public func updatePlan(_ plan: SessionPlan) {
        stateLock.lock()
        self.plan = plan
        stateLock.unlock()
    }

    /// A valid explicit Settings edit installs a fresh route for the next attempt. It never rolls
    /// back to the old route and never mutates the persisted preference in response to runtime health.
    public func updateBrainRoute(_ route: ConfiguredBrainRoute) {
        stateLock.lock()
        routeRevision &+= 1
        routeTopologyRevision &+= 1
        configuredRoute = route
        routeSession = BrainRouteSession(targetCount: route.targets.count)
        pendingTransitionOrigin = nil
        routeIsExhausted = false
        pendingExhaustionDeliveryGeneration = nil
        stateLock.unlock()
    }

    /// Refresh credential-bound clients for the same ordered route without changing session-local
    /// health.
    ///
    /// An in-flight attempt keeps its old client snapshot. Its failure is ignored because it belongs
    /// to the superseded credential, while its terminal success still resets route health. The next
    /// attempt uses replacement clients at the same forward-only cursor and failure count. When
    /// `providers` is supplied, clients for every other provider stay intact and an in-flight
    /// attempt on one of those providers keeps normal success/failure accounting.
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
        var retiredReplacements: [ConfiguredBrainTarget] = []
        let targets = zip(configuredRoute.targets, route.targets).enumerated().map {
            index, pair in
            let (current, replacement) = pair
            let shouldReplace = providers.map {
                $0.contains(replacement.target.provider)
            } ?? true
            guard shouldReplace else {
                return current
            }
            let isReachable = !routeIsExhausted && index >= routeSession.activeIndex
            guard isReachable else {
                retiredReplacements.append(replacement)
                return current
            }
            return replacement
        }
        configuredRoute = ConfiguredBrainRoute(
            targets: targets,
            onSelected: route.onSelected,
            onAdvanced: route.onAdvanced,
            onSkipped: route.onSkipped,
            onExhausted: route.onExhausted)
        let activeReplacement = refreshesActiveTarget && !routeIsExhausted
            ? configuredRoute.targets[routeSession.activeIndex]
            : nil
        stateLock.unlock()
        retiredReplacements.forEach { $0.terminate() }
        activeReplacement?.prepare()
        return true
    }

    /// Reconfigure clients for a non-topology Settings edit without changing route health or
    /// invalidating the attempt already in flight.
    ///
    /// Reasoning-effort changes use this boundary. The current attempt remains a valid attempt on
    /// the same target: its terminal success resets the failure sequence and its failure counts
    /// normally. Only a target identity/order change belongs to `updateBrainRoute(_:)`.
    @discardableResult
    public func reconfigureBrainRouteClients(_ route: ConfiguredBrainRoute) -> Bool {
        stateLock.lock()
        guard configuredRoute.targets.map(\.target) == route.targets.map(\.target) else {
            stateLock.unlock()
            return false
        }
        var retiredReplacements: [ConfiguredBrainTarget] = []
        let targets = zip(configuredRoute.targets, route.targets).enumerated().map {
            index, pair in
            let (current, replacement) = pair
            let isReachable = !routeIsExhausted && index >= routeSession.activeIndex
            guard isReachable else {
                retiredReplacements.append(replacement)
                return current
            }
            return replacement
        }
        configuredRoute = ConfiguredBrainRoute(
            targets: targets,
            onSelected: route.onSelected,
            onAdvanced: route.onAdvanced,
            onSkipped: route.onSkipped,
            onExhausted: route.onExhausted)
        let activeReplacement = routeIsExhausted
            ? nil
            : configuredRoute.targets[routeSession.activeIndex]
        stateLock.unlock()
        retiredReplacements.forEach { $0.terminate() }
        activeReplacement?.prepare()
        return true
    }

    /// Cancel background work that must not outlive the session, handing back the task so teardown
    /// can drain it before sealing the audit.
    ///
    /// Compaction runs off the attempt path, so `TurnTaskBox` does not own it. Without this a
    /// summary keeps a provider process alive and billing after Stop, and can still be writing when
    /// the session audit closes. The runner owns that lifecycle; this is the session's handle on it.
    @discardableResult
    public func cancelBackgroundWork() -> Task<Void, Never>? {
        runner.cancelBackgroundWork()
    }

    /// Provider state feeds both speakers into one aggregate gate. `hasPendingWork` means the provider
    /// still owns speech or transcript work, not merely that the audio waveform is non-silent.
    public func updateTranscriptionWork(_ hasPendingWork: Bool, for speaker: Speaker) {
        transcriptionSettlement.setUnsettled(hasPendingWork, for: speaker)
    }

    /// Admit one attempt only after both transcription streams are settled. Every automatic path
    /// reaches this boundary: the first trigger, a trigger queued behind an in-flight model call,
    /// and a pending-work retry. A manual hint is the explicit immediate exception.
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
            settledWork.bypassesTranscriptionSettlement = pending == .manualHint
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
            settledWork.bypassesTranscriptionSettlement = pending == .manualHint
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
        if routeIsExhausted {
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
            if trigger.reason == .manualHint {
                // A hint arriving after an automatic attempt has parked on unsettled speech must
                // wake that exact pending attempt. The trigger stays queued until the fresh-attempt
                // boundary consumes it together with the newest transcript.
                transcriptionSettlement.interruptWaiters()
            }
            return .pending
        }
        isHandling = true
        stateLock.unlock()
        return .claimed
    }

    private static func coalescing(
        _ existing: TriggerReason?,
        with incoming: TriggerReason
    ) -> TriggerReason {
        if existing == .manualHint || incoming == .manualHint {
            return .manualHint
        }
        // For natural wakes, the latest reason best describes the transcript snapshot the next
        // attempt will actually see (for example, turn-end supersedes an older silence wake).
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
            // A legacy/provider-less turn has no identity and must stay conservative when mixed
            // with identified turns; only fully identified callbacks are safe to suppress.
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

    /// Atomically take a coalesced trigger and the pulse generation at the same boundary. A later
    /// generation can then wake bounded backoff even if it arrives before the waiter is registered.
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

    /// Atomically take the next trigger or release the slot. A trigger arriving at the completion
    /// boundary can therefore never be orphaned.
    private func finishOrTakeNextTrigger() -> PendingTrigger? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let pendingTrigger {
            self.pendingTrigger = nil
            if !isCoveredByCommittedTranscript(pendingTrigger) {
                return pendingTrigger
            }
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

    /// Skip preflight-proven unavailable targets and return the next constructible target. Route
    /// transition callbacks run after the lock is released.
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
        guard !routeIsExhausted else {
            return BrainSelectionStep(alreadyExhausted: true)
        }

        var step = BrainSelectionStep()
        let index = routeSession.activeIndex
        let configured = configuredRoute.targets[index]
        if let brain = configured.brain {
            if let origin = pendingTransitionOrigin {
                step.advanced = RouteAdvanceDelivery(
                    topologyRevision: routeTopologyRevision,
                    previous: origin,
                    current: configured.target,
                    callback: configuredRoute.onAdvanced)
                pendingTransitionOrigin = nil
            }
            step.selected = AttemptBrain(
                // Snapshotted under the same lock as the target: one attempt, one revision.
                plan: plan,
                routeRevision: routeRevision,
                routeTopologyRevision: routeTopologyRevision,
                routeIndex: index,
                target: configured.target,
                brain: brain,
                summarizer: configured.summarizer,
                onSelected: configuredRoute.onSelected)
            return step
        }

        let failure = BrainFailure(
            disposition: .permanent,
            detail: configured.unavailabilityDetail
                ?? "\(configured.target.provider.displayName) is unavailable")
        step.diagnostic = "Jarvis coach: skipping unavailable route target "
            + "\(configured.target.provider.displayName): \(failure.detail)"
        step.skipped = RouteSkipDelivery(
            topologyRevision: routeTopologyRevision,
            target: configured.target,
            callback: configuredRoute.onSkipped)
        if pendingTransitionOrigin == nil {
            pendingTransitionOrigin = configured.target
        }
        switch routeSession.skipUnavailable() {
        case .advanced:
            break
        case .exhausted:
            routeIsExhausted = true
            pendingTrigger = nil
            exhaustionDeliveryGeneration &+= 1
            pendingExhaustionDeliveryGeneration = exhaustionDeliveryGeneration
            step.exhaustion = RouteExhaustionDelivery(
                generation: exhaustionDeliveryGeneration,
                topologyRevision: routeTopologyRevision,
                target: configured.target,
                failure: failure,
                callback: configuredRoute.onExhausted)
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
        _ failure: BrainFailure,
        on attempt: AttemptBrain
    ) async -> RouteFailureAction {
        let record = applyAttemptFailure(failure, on: attempt)
        record.retiredTarget?.terminate()
        if let exhaustion = record.exhaustion {
            return await deliverRouteExhaustion(exhaustion)
                ? record.action
                : .staleRevision
        }
        return record.action
    }

    private func applyAttemptFailure(
        _ failure: BrainFailure,
        on attempt: AttemptBrain
    ) -> (
        action: RouteFailureAction,
        exhaustion: RouteExhaustionDelivery?,
        retiredTarget: ConfiguredBrainTarget?
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if routeRevision != attempt.routeRevision
            || routeSession.activeIndex != attempt.routeIndex {
            return (.staleRevision, nil, nil)
        }

        switch routeSession.recordFailure(failure.disposition) {
        case .stay(let count):
            return (.retry(failureCount: count, advanced: false), nil, nil)
        case .advanced:
            pendingTransitionOrigin = attempt.target
            return (
                .retry(
                    failureCount: BrainRouteSession.failuresPerTarget,
                    advanced: true),
                nil,
                configuredRoute.targets[attempt.routeIndex])
        case .exhausted:
            routeIsExhausted = true
            pendingTrigger = nil
            exhaustionDeliveryGeneration &+= 1
            pendingExhaustionDeliveryGeneration = exhaustionDeliveryGeneration
            return (
                .exhausted,
                RouteExhaustionDelivery(
                    generation: exhaustionDeliveryGeneration,
                    topologyRevision: routeTopologyRevision,
                    target: attempt.target,
                    failure: failure,
                    callback: configuredRoute.onExhausted),
                configuredRoute.targets[attempt.routeIndex])
        }
    }

    private func recordAttemptSuccess(on attempt: AttemptBrain) {
        stateLock.lock()
        if routeTopologyRevision == attempt.routeTopologyRevision
            && routeSession.activeIndex == attempt.routeIndex {
            routeSession.recordSuccess()
        }
        stateLock.unlock()
    }

    /// Deliver one committed terminal transition exactly once.
    ///
    /// Client-only refreshes intentionally do not invalidate this token. An explicit route update
    /// clears it before this main-actor boundary and therefore supersedes the old terminal event.
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
            delivery.callback?(delivery.target, delivery.failure)

            // A callback may synchronously install an explicit replacement route. That edit
            // supersedes terminal teardown and preserves pending work on the new topology. A
            // same-topology client refresh does not change this revision.
            stateLock.lock()
            let remainsTerminal = routeIsExhausted
                && routeTopologyRevision == delivery.topologyRevision
            stateLock.unlock()
            return remainsTerminal
        }
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
            callback(delivery.target)
        }
    }

    func deliverRouteAdvance(_ delivery: RouteAdvanceDelivery) async {
        guard let callback = delivery.callback else { return }
        await MainActor.run {
            guard isCurrentRouteTopologyRevision(delivery.topologyRevision) else {
                jlog("Jarvis coach: ignoring route transition from a superseded Settings revision")
                return
            }
            callback(delivery.previous, delivery.current)
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
            jlog("… provider route already exhausted")
            return .brainError
        }

        var work = CoachAttemptRunner.PendingCoachingWork(reason: reason)
        var automaticSequence = 0
        var latestOutcome: TurnOutcome = .silentByModel

        while !Task.isCancelled {
            work = await waitForTranscriptionSettlement(before: work)
            if Task.isCancelled {
                releaseHandlingSlot()
                return .cancelled
            }
            guard let attempt = await selectBrainForAttempt() else {
                releaseHandlingSlot()
                return .brainError
            }

            let execution = await runner.runAttempt(work, using: attempt)
            switch execution.result {
            case .completed(let outcome):
                latestOutcome = outcome
                recordAttemptSuccess(on: attempt)
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
                let action = await recordAttemptFailure(failure, on: attempt)
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
                    releaseHandlingSlot()
                    return .brainError
                case .staleRevision:
                    routeChanged = true
                    jlog("Jarvis coach: preserving pending work from superseded route revision")
                case .retry(let failureCount, let advanced):
                    routeChanged = false
                    if !advanced {
                        activity?.record(
                            .coachingTurnFailed(provider: attempt.target.provider))
                    }
                    let policy = failure.disposition == .permanent
                        ? "permanent failure"
                        : "temporary/unknown failure \(failureCount)/\(BrainRouteSession.failuresPerTarget)"
                    let routeAction = advanced ? "; next fresh attempt advances the route" : ""
                    jlog("Jarvis coach: \(attempt.target.provider.displayName) \(policy)\(routeAction)")
                }

                var wake = takePendingTriggerSnapshot()
                var receivedTrigger = wake.trigger != nil
                var explicitManualWake = wake.trigger?.reason == .manualHint
                if let reason = wake.trigger?.reason {
                    failedWork.reason = Self.coalescing(failedWork.reason, with: reason)
                }
                work = failedWork
                automaticSequence += 1

                // A natural trigger and the automatic wake are the same pending attempt. Without a
                // natural wake, use a bounded delay so a quiet provider outage cannot spin.
                if wake.trigger == nil && !routeChanged {
                    await waitForAutomaticWakeOrDelay(
                        sequence: automaticSequence,
                        after: wake.generation)
                }
                if Task.isCancelled {
                    releaseHandlingSlot()
                    return .cancelled
                }

                // A trigger may arrive while the delay is sleeping. Consume it before the shared
                // admission boundary so an explicit manual hint retains its force-speak semantics.
                wake = takePendingTriggerSnapshot()
                if let reason = wake.trigger?.reason {
                    receivedTrigger = true
                    explicitManualWake = explicitManualWake || reason == .manualHint
                    work.reason = Self.coalescing(work.reason, with: reason)
                }
                work.bypassesTranscriptionSettlement = explicitManualWake
                work.wake = receivedTrigger ? .trigger : .pendingWork
            }
        }

        releaseHandlingSlot()
        return .cancelled
    }

}

/// Observable outcome of the trigger-coordination call. Provider failures may lead to more than one
/// fresh attempt before this call returns; every attempt still owns exactly one target.
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
