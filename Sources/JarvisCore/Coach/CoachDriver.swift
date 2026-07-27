import Foundation

/// The single-flight coaching coordinator.
///
/// A coaching attempt snapshots exactly one route target and owns that target for its complete tool
/// loop. Failed provider requests are never replayed inside the attempt. Instead, failed conversation
/// work stays uncommitted and this coordinator schedules a fresh attempt from the latest finalized
/// transcript plus provider-neutral observations completed earlier.
///
/// `@unchecked Sendable` is justified because mutable coordinator state is guarded by `stateLock`;
/// `CoachHistory`, transcript, and injected adapters are independently synchronized.
public final class CoachDriver: @unchecked Sendable {
    public typealias AutomaticAttemptDelay =
        @Sendable (_ consecutiveAutomaticAttempt: Int) async throws -> Void

    private let config: Config
    private let transcript: RollingTranscript
    private let screen: ScreenCapturing
    private let overlay: OverlayRendering
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let history = CoachHistory()
    private let speechActivity = SpeechActivityGate()
    private let automaticAttemptDelay: AutomaticAttemptDelay

    /// Safety backstop against a pathological model that loops on capture_screen forever.
    private let maxToolIterations = 4

    private let stateLock = NSLock()
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
    /// Transcript is committed only by a complete, non-truncated `speak` or `stay_silent`.
    private var committedTranscriptCount = 0
    /// Natural triggers coalesce while an attempt or automatic pending-work wait owns the slot.
    private var pendingTrigger: TriggerReason?
    /// Monotonic pulse used to race bounded automatic backoff against a newly coalesced trigger
    /// without losing a trigger that lands just before the async waiter is installed.
    private var pendingTriggerGeneration: UInt = 0
    private var pendingTriggerWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private struct AttemptBrain {
        let routeRevision: UInt
        let routeTopologyRevision: UInt
        let routeIndex: Int
        let target: BrainTarget
        let brain: BrainClient
        let summarizer: BrainClient?
        let onSelected: (@MainActor @Sendable (BrainTarget) -> Void)?
    }

    private struct PendingCoachingWork {
        var reason: TriggerReason
        /// Completed effects safe to carry between attempts and providers: ordinary user context
        /// only. At most the latest screen observation is retained. Never raw reasoning, tool ids,
        /// or call/result linkage.
        var observations: [ChatMessage] = []
        var manualHintPrepared = false
        /// Distinguishes a fresh natural event from a failed attempt whose automatic wake was
        /// coalesced with that event. Filler suppression must never cancel the latter.
        var hasFailedAttempt = false
    }

    private enum AttemptResult {
        case completed(TurnOutcome)
        case failed(
            outcome: TurnOutcome,
            failure: BrainFailure,
            work: PendingCoachingWork
        )
        case skipped(TurnOutcome)
        case cancelled
    }

    private struct RouteExhaustionDelivery {
        let generation: UInt
        let topologyRevision: UInt
        let target: BrainTarget
        let failure: BrainFailure
        /// Captured when exhaustion commits. A later same-topology client refresh must neither
        /// redirect the already-committed event to a second callback nor suppress this one.
        let callback: (@MainActor @Sendable (BrainTarget, BrainFailure) -> Void)?
    }

    /// A route-health notice committed under the lock and consumed once after crossing to the main
    /// actor. Client-only refreshes preserve it; an explicit topology edit supersedes it.
    private struct RouteSkipDelivery {
        let topologyRevision: UInt
        let target: BrainTarget
        let callback: (@MainActor @Sendable (BrainTarget) -> Void)?
    }

    /// The paired target transition committed when the next constructible target is selected.
    private struct RouteAdvanceDelivery {
        let topologyRevision: UInt
        let previous: BrainTarget
        let current: BrainTarget
        let callback: (@MainActor @Sendable (BrainTarget, BrainTarget) -> Void)?
    }

    private struct BrainSelectionStep {
        var selected: AttemptBrain? = nil
        var advanced: RouteAdvanceDelivery? = nil
        var skipped: RouteSkipDelivery? = nil
        var diagnostic: String? = nil
        var exhaustion: RouteExhaustionDelivery? = nil
        var alreadyExhausted = false
    }

    public init(
        config: Config,
        transcript: RollingTranscript,
        route: ConfiguredBrainRoute,
        screen: ScreenCapturing,
        overlay: OverlayRendering,
        clock: Clock,
        automaticAttemptDelay: AutomaticAttemptDelay? = nil
    ) {
        self.config = config
        self.transcript = transcript
        self.configuredRoute = route
        self.routeSession = BrainRouteSession(targetCount: route.targets.count)
        self.screen = screen
        self.overlay = overlay
        self.clock = clock
        self.sessionStart = clock.now()
        self.automaticAttemptDelay = automaticAttemptDelay ?? Self.defaultAutomaticAttemptDelay
    }

    private static let defaultAutomaticAttemptDelay: AutomaticAttemptDelay = { sequence in
        let seconds = min(0.5 * pow(2, Double(max(0, sequence - 1))), 4)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
        defer { stateLock.unlock() }
        guard configuredRoute.targets.map(\.target) == route.targets.map(\.target) else {
            return false
        }
        let refreshesActiveTarget = providers.map {
            $0.contains(configuredRoute.targets[routeSession.activeIndex].target.provider)
        } ?? true
        if refreshesActiveTarget {
            routeRevision &+= 1
        }
        let targets: [ConfiguredBrainTarget]
        if let providers {
            targets = zip(configuredRoute.targets, route.targets).map { current, replacement in
                providers.contains(replacement.target.provider) ? replacement : current
            }
        } else {
            targets = route.targets
        }
        configuredRoute = ConfiguredBrainRoute(
            targets: targets,
            onSelected: route.onSelected,
            onAdvanced: route.onAdvanced,
            onSkipped: route.onSkipped,
            onExhausted: route.onExhausted)
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
        defer { stateLock.unlock() }
        guard configuredRoute.targets.map(\.target) == route.targets.map(\.target) else {
            return false
        }
        configuredRoute = route
        return true
    }

    /// Realtime VAD feeds both speakers into one aggregate gate. Automatic pending-work attempts wait
    /// until both sides are inactive; natural triggers still coalesce while waiting.
    public func updateSpeechActivity(_ isActive: Bool, for speaker: Speaker) {
        speechActivity.setActive(isActive, for: speaker)
    }

    private func currentCommittedTranscriptCount() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return committedTranscriptCount
    }

    private func commitTranscript(through count: Int) {
        stateLock.lock()
        if count > committedTranscriptCount {
            committedTranscriptCount = count
        }
        stateLock.unlock()
    }

    private enum TriggerClaim {
        case claimed
        case pending
        case exhausted
    }

    private func claimOrPend(_ reason: TriggerReason) -> TriggerClaim {
        let waiters: [CheckedContinuation<Void, Never>]
        stateLock.lock()
        if routeIsExhausted {
            stateLock.unlock()
            return .exhausted
        }
        if isHandling {
            pendingTrigger = Self.coalescing(pendingTrigger, with: reason)
            pendingTriggerGeneration &+= 1
            waiters = Array(pendingTriggerWaiters.values)
            pendingTriggerWaiters.removeAll()
            stateLock.unlock()
            waiters.forEach { $0.resume() }
            if reason == .manualHint {
                // A hint arriving after an automatic attempt has parked on unsettled speech must
                // wake that exact pending attempt. The trigger stays queued until the fresh-attempt
                // boundary consumes it together with the newest transcript.
                speechActivity.interruptWaiters()
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

    /// Atomically take a coalesced trigger and the pulse generation at the same boundary. A later
    /// generation can then wake bounded backoff even if it arrives before the waiter is registered.
    private func takePendingTriggerSnapshot() -> (reason: TriggerReason?, generation: UInt) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let pending = pendingTrigger
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
    private func finishOrTakeNextTrigger() -> TriggerReason? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let pendingTrigger {
            self.pendingTrigger = nil
            return pendingTrigger
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

    private func takeBrainSelectionStep() -> BrainSelectionStep {
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
    ) -> (action: RouteFailureAction, exhaustion: RouteExhaustionDelivery?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if routeRevision != attempt.routeRevision
            || routeSession.activeIndex != attempt.routeIndex {
            return (.staleRevision, nil)
        }

        switch routeSession.recordFailure(failure.disposition) {
        case .stay(let count):
            return (.retry(failureCount: count, advanced: false), nil)
        case .advanced:
            pendingTransitionOrigin = attempt.target
            return (
                .retry(
                    failureCount: BrainRouteSession.failuresPerTarget,
                    advanced: true),
                nil)
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
                    callback: configuredRoute.onExhausted))
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

    private func deliverRouteSkip(_ delivery: RouteSkipDelivery) async {
        guard let callback = delivery.callback else { return }
        await MainActor.run {
            guard isCurrentRouteTopologyRevision(delivery.topologyRevision) else {
                jlog("Jarvis coach: ignoring target skip from a superseded Settings revision")
                return
            }
            callback(delivery.target)
        }
    }

    private func deliverRouteAdvance(_ delivery: RouteAdvanceDelivery) async {
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
    public func handleTrigger(_ reason: TriggerReason) async -> TurnOutcome {
        switch claimOrPend(reason) {
        case .claimed:
            break
        case .pending:
            jlog("… busy; batching this \(reason) into the pending conversation")
            return .busy
        case .exhausted:
            jlog("… provider route already exhausted")
            return .brainError
        }

        var work = PendingCoachingWork(reason: reason)
        var automaticSequence = 0
        var latestOutcome: TurnOutcome = .silentByModel

        while !Task.isCancelled {
            guard let attempt = await selectBrainForAttempt() else {
                releaseHandlingSlot()
                return .brainError
            }

            switch await runAttempt(work, using: attempt) {
            case .completed(let outcome):
                latestOutcome = outcome
                recordAttemptSuccess(on: attempt)
                automaticSequence = 0
                guard let next = finishOrTakeNextTrigger() else {
                    return latestOutcome
                }
                work = PendingCoachingWork(reason: next)

            case .skipped(let outcome):
                latestOutcome = outcome
                guard let next = finishOrTakeNextTrigger() else {
                    return latestOutcome
                }
                work = PendingCoachingWork(reason: next)

            case .cancelled:
                releaseHandlingSlot()
                return .cancelled

            case .failed(let outcome, let failure, var failedWork):
                latestOutcome = outcome
                let action = await recordAttemptFailure(failure, on: attempt)
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
                        ActivityLog.shared.record(
                            .coachingTurnFailed(provider: attempt.target.provider))
                    }
                    let policy = failure.disposition == .permanent
                        ? "permanent failure"
                        : "temporary/unknown failure \(failureCount)/\(BrainRouteSession.failuresPerTarget)"
                    let routeAction = advanced ? "; next fresh attempt advances the route" : ""
                    jlog("Jarvis coach: \(attempt.target.provider.displayName) \(policy)\(routeAction)")
                }

                var wake = takePendingTriggerSnapshot()
                var explicitManualWake = wake.reason == .manualHint
                if let reason = wake.reason {
                    failedWork.reason = Self.coalescing(failedWork.reason, with: reason)
                }
                failedWork.hasFailedAttempt = true
                work = failedWork
                automaticSequence += 1

                // A natural trigger and the automatic wake are the same pending attempt. Without a
                // natural wake, use a bounded delay so a quiet provider outage cannot spin.
                if wake.reason == nil && !routeChanged {
                    await waitForAutomaticWakeOrDelay(
                        sequence: automaticSequence,
                        after: wake.generation)
                }
                if Task.isCancelled {
                    releaseHandlingSlot()
                    return .cancelled
                }

                // A trigger may arrive while the delay is sleeping. Consume it before the fresh
                // attempt so an explicit manual hint retains its force-speak semantics. Snapshot
                // the speech-interrupt generation first so a hint landing between this trigger
                // snapshot and waiter registration cannot be lost.
                let speechInterruptGeneration = speechActivity.interruptGenerationSnapshot()
                wake = takePendingTriggerSnapshot()
                if let reason = wake.reason {
                    explicitManualWake = explicitManualWake || reason == .manualHint
                    work.reason = Self.coalescing(work.reason, with: reason)
                }
                if !explicitManualWake {
                    await speechActivity.waitUntilInactive(
                        unlessInterruptedAfter: speechInterruptGeneration)
                    // Consume a trigger that arrived while parked. Natural triggers still wait for
                    // speech inactivity; a manual hint interrupts that wait and turns this same
                    // pending-work attempt into the force-speak attempt.
                    wake = takePendingTriggerSnapshot()
                    if let reason = wake.reason {
                        work.reason = Self.coalescing(work.reason, with: reason)
                    }
                }
            }
        }

        releaseHandlingSlot()
        return .cancelled
    }

    /// Run one attempt on one immutable target snapshot.
    private func runAttempt(
        _ pendingWork: PendingCoachingWork,
        using attempt: AttemptBrain
    ) async -> AttemptResult {
        if Task.isCancelled {
            jlog("… attempt cancelled (stopped) before handling")
            return .cancelled
        }

        var work = pendingWork
        let reason = work.reason
        if case .silence(let seconds) = reason {
            jlog("🤫 quiet for \(Int(seconds))s")
        }

        let now = clock.now()
        let context = TriggerContext(
            reason: reason,
            sessionElapsedSeconds: now - sessionStart)
        let delta = transcript.renderFrom(index: currentCommittedTranscriptCount())

        // Filler-only natural events do not spend a provider attempt. A natural wake may also
        // coalesce with failed pending work whose transcript delta is empty (for example, a silence
        // attempt); that automatic attempt must still run.
        if reason == .turnEnd && !work.hasFailedAttempt
            && !delta.lines.contains(where: TurnSubstance.isSubstantive) {
            let preview = delta.lines.isEmpty
                ? "nothing new"
                : String(delta.lines.map(\.text).joined(separator: " · ").prefix(80))
            jlog("… skipped as filler (\(preview)) — not calling the brain")
            return .skipped(.skippedFillerOnly)
        }

        let historyBase: [ChatMessage] = [.system(coachSystemPrompt)] + history.snapshot()
        let userText = [
            delta.text.isEmpty ? nil : "New since last turn:\n\(delta.text)",
            context.promptLine,
        ].compactMap { $0 }.joined(separator: "\n\n")
        var turnMessages: [ChatMessage] = [.user(userText)] + work.observations

        if reason == .manualHint && !work.manualHintPrepared {
            if let prompt = context.promptLine {
                jlog("⌨️ hint shortcut — \(prompt)")
                ActivityLog.shared.record(.manualHint(prompt: prompt))
            }
            let screen = self.screen
            let shot = await Task.detached(
                priority: .userInitiated,
                operation: { screen.capture() }).value
            if Task.isCancelled {
                jlog("… attempt cancelled (stopped) after capture")
                return .cancelled
            }
            if let shot {
                jlog("👁 looking at your screen")
                ActivityLog.shared.record(.screenViewed(imageBase64JPEG: shot.imageBase64))
                var observations: [ChatMessage] = [.userImage(shot.imageBase64)]
                turnMessages.append(.userImage(shot.imageBase64))
                if let text = shot.recognizedText {
                    jlog("🔤 read \(text.count(where: { $0 == "\n" }) + 1) lines of on-screen text")
                    let observation = ChatMessage.user(Self.recognizedTextBlock(text))
                    observations.append(observation)
                    turnMessages.append(observation)
                }
                work.observations = observations
            } else {
                jlog("👁 screenshot failed")
                ActivityLog.shared.record(.screenViewFailed)
                work.observations = [
                    .user("The screen capture requested for the manual hint failed."),
                ]
            }
            work.manualHintPrepared = true
        }

        let toolChoice: ToolChoice =
            reason == .manualHint ? .force(speakTool.name) : .required
        jlog("💭 thinking… [\(attempt.target.provider.displayName)]")

        let screen = self.screen
        let actionBroker = CoachingActionBroker(
            identity: .init(configurationRevision: attempt.routeRevision),
            capture: {
                await Task.detached(
                    priority: .userInitiated,
                    operation: { screen.capture() }).value
            },
            captureObserver: { snapshot in
                Self.recordCaptureActivity(snapshot)
            })
        defer { actionBroker.invalidate() }

        var iterations = 0
        while iterations < maxToolIterations {
            iterations += 1
            let response: BrainResponse
            do {
                response = try await withTaskCancellationHandler {
                    try await attempt.brain.respond(
                        messages: historyBase + turnMessages,
                        tools: coachTools,
                        toolChoice: toolChoice,
                        actionBroker: actionBroker)
                } onCancel: {
                    actionBroker.invalidate()
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    jlog("… attempt cancelled (interrupted)")
                    return .cancelled
                }
                await preserveBrokerObservation(actionBroker, in: &work)
                let failure = BrainFailure(error)
                jlog("Jarvis coach: brain request failed on \(reason) via "
                     + "\(attempt.target.provider.displayName): \(failure.detail)")
                return .failed(outcome: .brainError, failure: failure, work: work)
            }

            if Task.isCancelled {
                jlog("… attempt cancelled (stopped) mid-think")
                return .cancelled
            }

            // Incomplete output cannot prove a terminal action, even if it happens to contain one.
            // Do not render a partial tip or execute a partial tool decision.
            if let incompleteReason = response.incompleteReason {
                await preserveBrokerObservation(actionBroker, in: &work)
                jlog("⚠️ response incomplete (\(incompleteReason)) — scheduling fresh attempt")
                return .failed(
                    outcome: .truncated,
                    failure: BrainFailure(
                        disposition: .temporary,
                        detail: "incomplete response: \(incompleteReason)"),
                    work: work)
            }

            do {
                switch response.actionDelivery {
                case .returnedCalls:
                    guard response.toolCalls.count <= 1 else {
                        try await actionBroker.rejectMultipleCallsInResponse()
                        preconditionFailure("rejectMultipleCallsInResponse always throws")
                    }
                    guard let call = response.toolCalls.first else {
                        _ = try await actionBroker.requireTerminal()
                        preconditionFailure("requireTerminal throws when no action was returned")
                    }
                    let result = try await withTaskCancellationHandler {
                        try await actionBroker.submit(call)
                    } onCancel: {
                        actionBroker.invalidate()
                    }
                    if case .capture(let snapshot) = result {
                        try Task.checkCancellation()
                        Self.appendCapture(
                            callID: call.callID,
                            snapshot: snapshot,
                            response: response,
                            to: &turnMessages,
                            work: &work)
                        continue
                    }

                case .broker:
                    guard response.toolCalls.isEmpty else {
                        try await actionBroker.rejectMultipleCallsInResponse()
                        preconditionFailure("rejectMultipleCallsInResponse always throws")
                    }
                    Self.appendBrokerCaptures(
                        await actionBroker.events(),
                        to: &turnMessages,
                        work: &work)
                }

                _ = try await actionBroker.requireTerminal()
                if Task.isCancelled {
                    jlog("… attempt cancelled (stopped) before committing action")
                    return .cancelled
                }
                let decision = try await actionBroker.commit()

                switch decision {
                case .speak(let callID, let lines):
                    jlog("💬 \(lines.joined(separator: " "))")
                    ActivityLog.shared.record(.tip(lines: lines))
                    overlay.render(
                        lines,
                        perLineSeconds: lines.map {
                            OverlayTiming.displaySeconds(for: $0, config: config)
                        })
                    let rawCalls = response.actionDelivery == .returnedCalls
                        ? response.rawToolCalls
                        : [decision.rawToolCall]
                    turnMessages.append(.assistantToolCalls(rawCalls))
                    turnMessages.append(.init(
                        role: .tool,
                        text: "shown to the user",
                        toolCallId: callID))
                    history.commit(turnMessages)
                    commitTranscript(through: delta.upTo)
                    await compactIfNeeded(using: attempt)
                    return .completed(.spoke)

                case .staySilent:
                    if Task.isCancelled {
                        jlog("… attempt cancelled (stopped) before recording silence")
                        return .cancelled
                    }
                    jlog("… nothing useful to add, staying silent")
                    ActivityLog.shared.record(.stayedSilent)
                    commitIfWorthKeeping(turnMessages, deltaText: delta.text)
                    commitTranscript(through: delta.upTo)
                    await compactIfNeeded(using: attempt)
                    return .completed(.silentByModel)
                }
            } catch {
                await preserveBrokerObservation(actionBroker, in: &work)
                let failure = BrainFailure(error)
                jlog("Jarvis coach: invalid coaching action via "
                     + "\(attempt.target.provider.displayName): \(failure.detail)")
                return .failed(outcome: .brainError, failure: failure, work: work)
            }
        }

        jlog("⚠️ tool loop exhausted — scheduling fresh attempt")
        return .failed(
            outcome: .exhausted,
            failure: BrainFailure(
                disposition: .temporary,
                detail: "coaching tool loop exhausted"),
            work: work)
    }

    private static func recordCaptureActivity(_ snapshot: ScreenSnapshot?) {
        if let snapshot {
            jlog("👁 looking at your screen")
            ActivityLog.shared.record(.screenViewed(imageBase64JPEG: snapshot.imageBase64))
            if let text = snapshot.recognizedText {
                jlog("🔤 read \(text.count(where: { $0 == "\n" }) + 1) lines of on-screen text")
            }
        } else {
            jlog("👁 screenshot failed")
            ActivityLog.shared.record(.screenViewFailed)
        }
    }

    private static func appendBrokerCaptures(
        _ events: [CoachingActionBroker.Event],
        to turnMessages: inout [ChatMessage],
        work: inout PendingCoachingWork
    ) {
        for event in events {
            guard case .captured(let callID, let snapshot) = event else { continue }
            let raw = RawToolCall(
                id: callID,
                name: captureScreenTool.name,
                argumentsJSON: "{}")
            appendCapture(
                callID: callID,
                snapshot: snapshot,
                rawAssistantMessage: .assistantToolCalls([raw]),
                to: &turnMessages,
                work: &work)
        }
    }

    private static func appendCapture(
        callID: String,
        snapshot: ScreenSnapshot?,
        response: BrainResponse,
        to turnMessages: inout [ChatMessage],
        work: inout PendingCoachingWork
    ) {
        let assistantMessage: ChatMessage = response.outputItemsJSON.isEmpty
            ? .assistantToolCalls(response.rawToolCalls)
            : .rawItems(response.outputItemsJSON)
        appendCapture(
            callID: callID,
            snapshot: snapshot,
            rawAssistantMessage: assistantMessage,
            to: &turnMessages,
            work: &work)
    }

    private static func appendCapture(
        callID: String,
        snapshot: ScreenSnapshot?,
        rawAssistantMessage: ChatMessage,
        to turnMessages: inout [ChatMessage],
        work: inout PendingCoachingWork
    ) {
        turnMessages.append(rawAssistantMessage)
        if let snapshot {
            turnMessages.append(.init(
                role: .tool,
                text: captureResultText(snapshot),
                toolCallId: callID))
            turnMessages.append(.userImage(snapshot.imageBase64))
            work.observations = [
                .user(captureResultText(snapshot)),
                .userImage(snapshot.imageBase64),
            ]
        } else {
            turnMessages.append(.init(
                role: .tool,
                text: "screenshot failed",
                toolCallId: callID))
            work.observations = [
                .user("A screen capture requested earlier in this turn failed."),
            ]
        }
    }

    private func preserveBrokerObservation(
        _ broker: CoachingActionBroker,
        in work: inout PendingCoachingWork
    ) async {
        guard await broker.hasCaptureAttempt() else { return }
        if let snapshot = await broker.latestCapture() {
            work.observations = [
                .user(Self.captureResultText(snapshot)),
                .userImage(snapshot.imageBase64),
            ]
        } else {
            work.observations = [
                .user("A screen capture requested earlier in this turn failed."),
            ]
        }
    }

    private func commitIfWorthKeeping(_ turn: [ChatMessage], deltaText: String) {
        guard !deltaText.isEmpty || turn.count > 1 else { return }
        history.commit(turn)
    }

    private static func captureResultText(_ shot: ScreenSnapshot) -> String {
        guard let text = shot.recognizedText else { return "screenshot captured" }
        return "screenshot captured\n\n\(recognizedTextBlock(text))"
    }

    private static func recognizedTextBlock(_ text: String) -> String {
        "\(CoachHistory.ocrHeader)\n\(text)"
    }

    // MARK: - History compaction

    /// Auxiliary compaction fails soft and never counts against provider route health.
    private func compactIfNeeded(using attempt: AttemptBrain) async {
        guard history.estimatedTokens > config.historyCompactionTokenThreshold else { return }
        guard let (oldest, count) = history.compactionPrefix() else { return }
        do {
            let response = try await (attempt.summarizer ?? attempt.brain).respond(
                messages: [.system(Self.summaryInstructions), .user(Self.renderForSummary(oldest))],
                tools: [],
                toolChoice: .auto)
            guard let summary = response.outputText, !summary.isEmpty else {
                jlog("… memory compaction returned nothing — keeping full history for now")
                return
            }
            history.compact(prefixCount: count, summary: summary)
            jlog("… condensed session memory to ~\(history.estimatedTokens) tokens")
        } catch {
            jlog("… memory compaction failed (will retry later): \(error.localizedDescription)")
        }
    }

    private static let summaryInstructions = """
    You condense a live coding-interview coaching session's history into a briefing the coach will \
    rely on for the rest of the session. Keep, in this order: the interview problem statement (all \
    load-bearing details); the user's current approach and how far they've got; every tip the coach \
    already gave (so it isn't repeated); any open questions or requirements from the interviewer. \
    Plain text, under 250 words. Output only the briefing.
    """

    private static func renderForSummary(_ messages: [ChatMessage]) -> String {
        messages.map { message in
            if let calls = message.toolCalls {
                return calls.map { "coach called \($0.name)" }.joined(separator: "\n")
            }
            if message.imageBase64JPEG != nil { return "[screenshot]" }
            let text = message.text ?? ""
            return message.role == .tool ? "tool result: \(text)" : text
        }.joined(separator: "\n")
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

private extension ToolInvocation {
    var callID: String {
        switch self {
        case .captureScreen(let callID), .speak(let callID, _), .staySilent(let callID):
            return callID
        }
    }
}
