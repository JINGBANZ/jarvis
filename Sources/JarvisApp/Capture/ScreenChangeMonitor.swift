import Foundation
import JarvisCore

/// Two-stage, session-local visual monitor.
///
/// Stage A compares low-rate 320 px one-shot captures locally, without creating a persistent macOS
/// screen-sharing session. Stage B takes one full-resolution screenshot and runs OCR only after
/// quiescence. Stable snapshots wait briefly to piggyback on the next audio-triggered coach turn;
/// otherwise one screen-only turn is allowed per configured minimum interval. No intermediate pixels
/// or OCR are persisted, and request failure/cancellation re-arms the exact candidate.
@MainActor
final class ScreenChangeMonitor {
    typealias ChangeHandler = @MainActor @Sendable (ScreenSnapshot) -> Void
    typealias Capture = @Sendable () async -> ScreenSnapshot?

    private let preferences: ScreenCapturePreferences
    private let capture: Capture
    private let frameInterval: TimeInterval
    private let minimumRequestInterval: TimeInterval
    private let piggybackWait: TimeInterval
    private let minimumChangedAreaRatio: Double
    private let onChange: ChangeHandler
    private var activityDetector: ScreenActivityDetector
    private var contentDetector = ScreenChangeDetector(requiredStablePollCount: 1)

    private var activityPoller: ScreenActivityPoller?
    private var seedTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var generation = 0
    /// Prevents an asynchronously completed startup capture from baselining content that the local
    /// poller has already identified as a post-start change.
    private var observedChangeBeforeSeedCompleted = false

    private var pendingSnapshot: ScreenSnapshot?
    private var pendingCandidateID: ScreenActivityDetector.CandidateID?
    private var inFlightSnapshot: ScreenSnapshot?
    private var inFlightCandidateID: ScreenActivityDetector.CandidateID?
    private var lastVisualRequestAt: TimeInterval?
    private var latestObservedChangeAt: TimeInterval?

    // Content-free operational evidence, summarized once per minute instead of logging every frame.
    private var changedFrameCount = 0
    private var idleFrameCount = 0
    private var pixelChangeFrameCount = 0
    private var unclassifiableFrameCount = 0
    private var ignoredFrameCount = 0
    private var fullCaptureCount = 0
    private var duplicateCount = 0
    private var piggybackCount = 0
    private var screenOnlyCount = 0
    private var lastDiagnosticAt = ProcessInfo.processInfo.systemUptime

    init(preferences: ScreenCapturePreferences, capture: @escaping Capture,
         config: Config, onChange: @escaping ChangeHandler) {
        self.preferences = preferences
        self.capture = capture
        self.frameInterval = config.screenMonitorFrameIntervalSeconds
        self.minimumRequestInterval = config.screenMonitorMinimumRequestIntervalSeconds
        self.piggybackWait = config.screenMonitorPiggybackWaitSeconds
        self.minimumChangedAreaRatio = config.screenMonitorMinimumChangedAreaRatio
        self.onChange = onChange
        self.activityDetector = ScreenActivityDetector(
            quiescenceInterval: config.screenMonitorQuiescenceSeconds,
            minimumChangedAreaRatio: config.screenMonitorMinimumChangedAreaRatio)
    }

    func start() {
        guard activityPoller == nil else { return }
        let requestedGeneration = generation
        observedChangeBeforeSeedCompleted = false
        let poller = ScreenActivityPoller(
            preferences: preferences, frameInterval: frameInterval,
            minimumChangedAreaRatio: minimumChangedAreaRatio
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.receive(event, generation: requestedGeneration)
            }
        }
        activityPoller = poller

        // Seed content separately from activity. The first low-resolution poll establishes only the
        // activity baseline; a full-content baseline prevents the first real question/code change
        // from being swallowed by duplicate suppression.
        let capture = capture
        seedTask = Task { [weak self, capture] in
            let snapshot = await capture()
            guard !Task.isCancelled, let self,
                  self.generation == requestedGeneration, let snapshot else { return }
            guard !self.observedChangeBeforeSeedCompleted else { return }
            _ = self.contentDetector.seedIfNeeded(snapshot)
        }
        poller.start()
    }

    /// Takes a stable snapshot for the next spoken turn. This adds current visual context to a request
    /// that was already going to happen, so the monitor incurs no extra coach call.
    func takePendingSnapshotForSpeech() -> ScreenSnapshot? {
        guard inFlightSnapshot == nil,
              let snapshot = pendingSnapshot,
              let candidateID = pendingCandidateID else { return nil }
        fallbackTask?.cancel()
        fallbackTask = nil
        pendingSnapshot = nil
        pendingCandidateID = nil
        inFlightSnapshot = snapshot
        inFlightCandidateID = candidateID
        lastVisualRequestAt = Self.now()
        piggybackCount += 1
        return snapshot
    }

    /// Acknowledges any screen the coach actually consumed. Candidate IDs and monotonic capture
    /// ordering prevent a late acknowledgement from clearing a newer dirty-frame burst.
    func observe(_ snapshot: ScreenSnapshot) {
        let inFlightID = inFlightCandidateID
        let pendingID = pendingCandidateID
        if !ScreenCaptureOrdering.canAcknowledge(
            capturedAt: snapshot.capturedAt,
            latestObservedChangeAt: latestObservedChangeAt,
            isMonitorSnapshot: inFlightID != nil
        ) {
            // This ordinary screenshot was captured before the monitor observed its newest change.
            // The request still counts against visual spend, but it must not acknowledge, baseline,
            // or clear the newer candidate. Recompute an existing fallback from the new rate limit.
            lastVisualRequestAt = Self.now()
            if pendingSnapshot != nil { scheduleFallback() }
            return
        }
        if let inFlightID {
            _ = activityDetector.acknowledge(inFlightID)
        } else if let pendingID {
            _ = activityDetector.acknowledge(pendingID)
        } else {
            // A manual/silence/model-requested screenshot is a fresh baseline in its own right.
            activityDetector.reset()
        }
        contentDetector.observe(snapshot)
        pendingSnapshot = nil
        pendingCandidateID = nil
        inFlightSnapshot = nil
        inFlightCandidateID = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        lastVisualRequestAt = Self.now()
        resumeAwaitingCandidateIfPossible()
    }

    /// Re-arms the exact monitor snapshot after the first request carrying it failed or was displaced.
    func retryUnacknowledgedChange() {
        guard let snapshot = inFlightSnapshot, let candidateID = inFlightCandidateID else { return }
        inFlightSnapshot = nil
        inFlightCandidateID = nil
        contentDetector.retryUnacknowledgedChange()
        guard activityDetector.reject(candidateID) else {
            // A newer native frame already superseded this screenshot; let that candidate win.
            resumeAwaitingCandidateIfPossible()
            return
        }
        pendingSnapshot = snapshot
        pendingCandidateID = candidateID
        scheduleFallback()
    }

    func stop() {
        generation &+= 1
        activityPoller?.stop()
        activityPoller = nil
        seedTask?.cancel(); seedTask = nil
        captureTask?.cancel(); captureTask = nil
        fallbackTask?.cancel(); fallbackTask = nil
        pendingSnapshot = nil
        pendingCandidateID = nil
        inFlightSnapshot = nil
        inFlightCandidateID = nil
        lastVisualRequestAt = nil
        latestObservedChangeAt = nil
        observedChangeBeforeSeedCompleted = false
        activityDetector.reset()
        contentDetector.reset()
    }

    private func receive(_ event: ScreenActivityPoller.Event, generation: Int) {
        guard generation == self.generation else { return }
        let result: ScreenActivityDetector.ObservationResult
        switch event {
        case .changed(let areaRatio, let evidence):
            let observedAt = Self.now()
            latestObservedChangeAt = observedAt
            observedChangeBeforeSeedCompleted = true
            changedFrameCount += 1
            switch evidence {
            case .visualPixels: pixelChangeFrameCount += 1
            case .boundedDirtyRegion: break
            }
            let observation = activityDetector.observe(
                .contentChanged(changedAreaRatio: areaRatio), at: observedAt)
            // A newer significant visual burst makes a not-yet-sent full capture stale. Re-arm the
            // content detector before dropping it: if a caret/selection blink settles back to that
            // same question or code, the exact content remains eligible instead of being stuck in
            // awaiting-acknowledgement state. In-flight delivery is allowed to finish; its candidate
            // ID cannot erase this newer burst.
            if pendingSnapshot != nil, observation != .ignored {
                contentDetector.retryUnacknowledgedChange()
                pendingSnapshot = nil
                pendingCandidateID = nil
                fallbackTask?.cancel()
                fallbackTask = nil
            }
            result = observation
        case .idle:
            idleFrameCount += 1
            result = activityDetector.observe(.idle, at: Self.now())
        case .unclassifiable:
            unclassifiableFrameCount += 1
            logDiagnosticsIfDue()
            return
        }

        switch result {
        case .ignored:
            ignoredFrameCount += 1
        case .stableChange(let candidateID):
            captureStableCandidate(candidateID, generation: generation)
        case .awaitingAcknowledgement(let candidateID):
            // This can be a newer candidate that became stable while an older request was in flight.
            // Re-offering it is idempotent: the capture guard preserves the single in-flight bound.
            captureStableCandidate(candidateID, generation: generation)
        case .idle, .waitingForQuiescence:
            break
        }
        logDiagnosticsIfDue()
    }

    private func captureStableCandidate(_ candidateID: ScreenActivityDetector.CandidateID,
                                        generation: Int) {
        guard captureTask == nil, pendingSnapshot == nil, inFlightSnapshot == nil else { return }
        let capture = capture
        captureTask = Task { [weak self, capture] in
            let snapshot = await capture()
            guard let self else { return }
            self.captureTask = nil
            guard !Task.isCancelled, self.generation == generation else { return }
            guard let snapshot else {
                let rejected = self.activityDetector.reject(candidateID)
                if !rejected { self.resumeAwaitingCandidateIfPossible() }
                return
            }
            self.fullCaptureCount += 1

            if !self.contentDetector.isSeeded {
                // A failed startup seed must not hide the first actual dirty-frame burst.
                self.contentDetector.observe(snapshot)
                self.queue(snapshot, candidateID: candidateID)
                return
            }

            switch self.contentDetector.poll(snapshot) {
            case .stableChange:
                self.queue(snapshot, candidateID: candidateID)
            case .unchanged, .awaitingAcknowledgement:
                self.duplicateCount += 1
                let acknowledged = self.activityDetector.acknowledge(candidateID)
                if !acknowledged { self.resumeAwaitingCandidateIfPossible() }
            case .dormant:
                self.contentDetector.observe(snapshot)
                self.queue(snapshot, candidateID: candidateID)
            case .waitingForStability:
                // The monitor configures this detector for one observation; keep the branch explicit
                // so a future configuration change fails safe by retrying the candidate.
                _ = self.activityDetector.reject(candidateID)
            }
        }
    }

    private func queue(_ snapshot: ScreenSnapshot,
                       candidateID: ScreenActivityDetector.CandidateID) {
        pendingSnapshot = snapshot
        pendingCandidateID = candidateID
        scheduleFallback()
    }

    private func resumeAwaitingCandidateIfPossible() {
        guard captureTask == nil, pendingSnapshot == nil, inFlightSnapshot == nil else { return }
        let result = activityDetector.observe(.idle, at: Self.now())
        switch result {
        case .stableChange(let candidateID), .awaitingAcknowledgement(let candidateID):
            captureStableCandidate(candidateID, generation: generation)
        case .idle, .ignored, .waitingForQuiescence:
            break
        }
    }

    private func scheduleFallback() {
        fallbackTask?.cancel()
        let now = Self.now()
        let deadline = ScreenRequestTiming.fallbackDeadline(
            candidateAt: now,
            lastVisualRequestAt: lastVisualRequestAt,
            piggybackWait: piggybackWait,
            minimumRequestInterval: minimumRequestInterval)
        let delay = max(0, deadline - now)
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.emitScreenOnly()
        }
    }

    private func emitScreenOnly() {
        guard inFlightSnapshot == nil,
              let snapshot = pendingSnapshot,
              let candidateID = pendingCandidateID else { return }
        pendingSnapshot = nil
        pendingCandidateID = nil
        inFlightSnapshot = snapshot
        inFlightCandidateID = candidateID
        fallbackTask = nil
        lastVisualRequestAt = Self.now()
        screenOnlyCount += 1
        onChange(snapshot)
    }

    private func logDiagnosticsIfDue() {
        let now = Self.now()
        guard now - lastDiagnosticAt >= 60 else { return }
        lastDiagnosticAt = now
        jlog("Jarvis screen witness (60s): polls_changed=\(changedFrameCount), "
             + "polls_idle=\(idleFrameCount), pixel_changes=\(pixelChangeFrameCount), "
             + "poll_failures=\(unclassifiableFrameCount), "
             + "ignored=\(ignoredFrameCount), full_captures=\(fullCaptureCount), "
             + "duplicates=\(duplicateCount), piggybacks=\(piggybackCount), "
             + "screen_only=\(screenOnlyCount)")
        changedFrameCount = 0
        idleFrameCount = 0
        pixelChangeFrameCount = 0
        unclassifiableFrameCount = 0
        ignoredFrameCount = 0
        fullCaptureCount = 0
        duplicateCount = 0
        piggybackCount = 0
        screenOnlyCount = 0
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    deinit {
        seedTask?.cancel()
        captureTask?.cancel()
        fallbackTask?.cancel()
    }
}
