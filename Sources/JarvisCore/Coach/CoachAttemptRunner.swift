import Foundation

/// The committed-transcript boundary, the one datum both halves of the coaching kernel share.
///
/// The scheduler reads it to decide whether a late turn-end trigger is already covered by speech an
/// earlier attempt committed; the attempt runner reports into it when a complete, non-truncated
/// terminal action commits. It only ever grows, which is why a plain leaf lock is enough and why
/// neither half has to hold the other's.
///
/// `@unchecked Sendable`: the count is guarded by `lock`.
final class CoachTranscriptLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var committed = 0

    var committedCount: Int {
        lock.withLock { committed }
    }

    func commit(through count: Int) {
        lock.withLock {
            if count > committed { committed = count }
        }
    }
}

/// Runs one coaching attempt against one snapshotted target, and keeps the session's history.
///
/// This is the *attempt runner* half of the coaching kernel (wiki/lean-coaching-core.md, Phase 5).
/// The state-ownership boundary with `CoachDriver`, the scheduler half:
///
/// - **The scheduler owns** trigger coalescing and pending-trigger generations, transcription
///   settlement, the single-flight handling slot, and forward-only route state — selection,
///   advance, skip, exhaustion, and the delivery tokens that make a terminal transition land
///   exactly once. All of it lives under the driver's one lock.
/// - **This type owns** the execution of one attempt: filler classification, the bounded tool loop,
///   the `capture_screen` continuation, overlay delivery, history commit, and off-path history
///   compaction with its own cancellation lifecycle. It also owns attempt identity, which nothing
///   outside an attempt reads.
///
/// The interface between the halves is one call per attempt — an immutable `AttemptBrain` plus the
/// pending work in, an `AttemptExecution` out — over the shared `CoachTranscriptLedger`. Nothing
/// here schedules, advances a route, retries, or coalesces a trigger.
///
/// `@unchecked Sendable` is justified because `runnerLock` guards the compaction lifecycle and
/// attempt numbering; `CoachHistory`, the transcript, the ledger, and the injected adapters are
/// independently synchronized.
final class CoachAttemptRunner: @unchecked Sendable {
    private let config: Config
    private let transcript: RollingTranscript
    private let screen: ScreenCapturing
    private let overlay: OverlayRendering
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let history = CoachHistory()
    private let coachingAttempts: (any CoachingAttemptAuditing)?
    private let activity: (any ActivityEventRecording)?
    private let ledger: CoachTranscriptLedger
    /// Fixed for the whole session — chosen once at Start, never reclassified — so it needs none of
    /// `prepMaterial`'s live-swap machinery; a plain stored `let` is enough.
    private let interviewFormatAddendum: String

    private let runnerLock = NSLock()
    private var nextAttemptID = 0
    /// Guards the single off-path compaction run (see `startCompactionIfIdle`).
    private var isCompacting = false
    /// A compaction asked for while one was already running, run once the current pass ends.
    private var compactionRequested = false
    /// The in-flight pass, so session teardown can cancel and drain it.
    private var compactionTask: Task<Void, Never>?
    /// Latched by teardown: no further background pass may start on a stopped session.
    private var backgroundWorkStopped = false

    init(
        config: Config,
        transcript: RollingTranscript,
        screen: ScreenCapturing,
        overlay: OverlayRendering,
        clock: Clock,
        sessionStart: TimeInterval,
        coachingAttempts: (any CoachingAttemptAuditing)?,
        activity: (any ActivityEventRecording)?,
        ledger: CoachTranscriptLedger,
        interviewFormatAddendum: String = ""
    ) {
        self.config = config
        self.transcript = transcript
        self.screen = screen
        self.overlay = overlay
        self.clock = clock
        self.sessionStart = sessionStart
        self.coachingAttempts = coachingAttempts
        self.activity = activity
        self.ledger = ledger
        self.interviewFormatAddendum = interviewFormatAddendum
    }

    private func takeNextAttemptID() -> Int {
        runnerLock.withLock {
            nextAttemptID += 1
            return nextAttemptID
        }
    }

    /// Safety backstop against a pathological model that loops on capture_screen forever.
    private let maxToolIterations = 4

    struct PendingCoachingWork {
        var reason: TriggerReason
        /// Only an explicit hotkey wake may cross unsettled transcription. A retry of a failed
        /// manual hint is automatic and resets this bit unless another hotkey press joins it.
        var bypassesTranscriptionSettlement: Bool
        var wake: CoachingAttemptAuditEvent.Wake = .trigger
        /// Completed effects safe to carry between attempts and providers: ordinary user context
        /// only, one independently-replaceable slot per contributing tool — at most the latest
        /// screen observation, at most the latest search result. A flat, appended-to array can't
        /// express this: `work` also carries forward verbatim into a retry after a failure
        /// (`CoachDriver.swift`'s `work = failedWork`), so a second search on that retry must
        /// replace the first search's stale result, not accumulate alongside it — while still never
        /// disturbing whatever the screen slot holds, and vice versa. Never raw reasoning, tool ids,
        /// or call/result linkage.
        var screenObservation: [ChatMessage] = []
        var prepNotesObservation: ChatMessage?
        /// Every carried observation, screen first, in the order the model should see them.
        var observations: [ChatMessage] {
            screenObservation + (prepNotesObservation.map { [$0] } ?? [])
        }
        var manualHintPrepared = false

        init(reason: TriggerReason) {
            self.reason = reason
            bypassesTranscriptionSettlement = reason == .manualHint
        }
    }

    enum AttemptResult {
        case completed(TurnOutcome)
        case failed(
            outcome: TurnOutcome,
            failure: BrainFailure,
            work: PendingCoachingWork
        )
        case skipped(TurnOutcome)
        case cancelled
    }

    struct AttemptExecution {
        let id: Int?
        let result: AttemptResult
    }

    /// Run one attempt on one immutable target snapshot.
    func runAttempt(
        _ pendingWork: PendingCoachingWork,
        using attempt: CoachDriver.AttemptBrain
    ) async -> AttemptExecution {
        if Task.isCancelled {
            jlog("… attempt cancelled (stopped) before handling")
            return AttemptExecution(id: nil, result: .cancelled)
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
        let transcriptStartIndex = ledger.committedCount
        let delta = transcript.renderFrom(index: transcriptStartIndex)
        let classifications = delta.lines.map { TurnSubstance.classification(of: $0.text) }
        let brainFacingOffsets = classifications.indices.filter {
            classifications[$0].isSubstantive
        }
        let substantiveLines = brainFacingOffsets.map { delta.lines[$0] }
        let brainFacingTranscriptIndices = Set(brainFacingOffsets.map {
            transcriptStartIndex + $0
        })
        let substantiveDeltaText = RollingTranscript.render(substantiveLines)
        let attemptID = takeNextAttemptID()
        coachingAttempts?.recordStarted(
            attemptID: attemptID,
            wake: work.wake,
            reason: reason,
            target: attempt.target,
            transcriptStartIndex: transcriptStartIndex,
            transcriptLines: delta.lines,
            classifications: classifications,
            brainFacingTranscriptIndices: brainFacingTranscriptIndices)

        let userText = [
            substantiveDeltaText.isEmpty
                ? nil
                : JarvisPrompts.Coach.newSpeech(substantiveDeltaText),
            context.promptLine,
        ].compactMap { $0 }.joined(separator: "\n\n")
        var turnMessages = userText.isEmpty ? work.observations : [.user(userText)] + work.observations

        // A request needs meaningful speech, a trigger instruction, or a provider-neutral
        // observation completed by the failed attempt. Activity has already retained finalized
        // filler, so an empty fresh attempt has no value to send and needs no synthetic placeholder.
        if turnMessages.isEmpty {
            let preview = delta.lines.isEmpty
                ? "nothing new"
                : String(delta.lines.map(\.text).joined(separator: " · ").prefix(80))
            jlog("… skipped as filler (\(preview)) — not calling the brain")
            ledger.commit(through: delta.upTo)
            return AttemptExecution(id: attemptID, result: .skipped(.skippedFillerOnly))
        }
        // Describing search_prep_notes when it isn't actually offered invites the model to call a
        // tool it doesn't have — and that call is a hard attempt failure (below), so `prepMaterial`
        // must track the real tool set (`tools`, below) exactly, not just hint at it.
        let systemPrompt = JarvisPrompts.Coach.system(
            prepMaterial: attempt.prepMaterial != nil,
            formatAddendum: interviewFormatAddendum)
        let historyBase: [ChatMessage] = [.system(systemPrompt)] + history.snapshot()

        if reason == .manualHint && !work.manualHintPrepared {
            if let prompt = context.promptLine {
                jlog("⌨️ hint shortcut — \(prompt)")
                activity?.record(.manualHint(prompt: prompt))
            }
            let screen = self.screen
            let shot = await Self.captureScreen(using: screen, selecting: attempt.plan.screen)
            if Task.isCancelled {
                jlog("… attempt cancelled (stopped) after capture")
                return AttemptExecution(id: attemptID, result: .cancelled)
            }
            if let shot {
                jlog("👁 looking at your screen")
                activity?.record(.screenViewed(imageBase64JPEG: shot.imageBase64))
                var observations: [ChatMessage] = [.userImage(shot.imageBase64)]
                turnMessages.append(.userImage(shot.imageBase64))
                if let text = shot.recognizedText {
                    jlog("🔤 read \(text.count(where: { $0 == "\n" }) + 1) lines of on-screen text")
                    let observation = ChatMessage.user(JarvisPrompts.Coach.recognizedText(text))
                    observations.append(observation)
                    turnMessages.append(observation)
                }
                work.screenObservation = observations
            } else {
                jlog("👁 screenshot failed")
                activity?.record(.screenViewFailed)
                work.screenObservation = [
                    .user(JarvisPrompts.Coach.manualHintCaptureFailed),
                ]
            }
            work.manualHintPrepared = true
        }

        let toolChoice: ToolChoice =
            reason == .manualHint ? .force(speakTool.name) : .required
        jlog("💭 thinking… [\(attempt.target.provider.displayName)]")

        var requestPhase: CoachingAttemptAuditEvent.RequestPhase = .initial
        var requestSequence = 1
        let conversation: any BrainConversation
        do {
            let requestContext = CoachingRequestAttribution.context(
                attemptID: attemptID,
                wake: work.wake,
                reason: reason,
                phase: requestPhase,
                sequence: requestSequence)
            conversation = try await CoachingRequestAttribution.$current.withValue(requestContext) {
                try await attempt.brain.makeConversation()
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                jlog("… attempt cancelled (interrupted)")
                return AttemptExecution(id: attemptID, result: .cancelled)
            }
            let failure = BrainFailure(error)
            jlog("Jarvis coach: brain conversation failed on \(reason) via "
                 + "\(attempt.target.provider.displayName): \(failure.detail)")
            return AttemptExecution(
                id: attemptID,
                result: .failed(outcome: .brainError, failure: failure, work: work))
        }

        // search_prep_notes joins the fixed set only when a source actually indexed usable text —
        // a session without prep material offers a tool set identical to before this feature existed.
        let tools: [ToolDef] = attempt.prepMaterial != nil ? coachTools + [searchPrepNotesTool] : coachTools

        let result: AttemptResult = await { () async -> AttemptResult in
            var iterations = 0
            while iterations < maxToolIterations {
                iterations += 1
                let response: BrainResponse
                do {
                    let requestContext = CoachingRequestAttribution.context(
                        attemptID: attemptID,
                        wake: work.wake,
                        reason: reason,
                        phase: requestPhase,
                        sequence: requestSequence)
                    response = try await CoachingRequestAttribution.$current.withValue(requestContext) {
                        try await conversation.respond(
                            messages: historyBase + turnMessages,
                            tools: tools,
                            toolChoice: toolChoice)
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        jlog("… attempt cancelled (interrupted)")
                        return .cancelled
                    }
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
                    jlog("⚠️ response incomplete (\(incompleteReason)) — scheduling fresh attempt")
                    return .failed(
                        outcome: .truncated,
                        failure: BrainFailure(
                            disposition: .temporary,
                            detail: "incomplete response: \(incompleteReason)"),
                        work: work)
                }

                guard let call = response.toolCalls.first else {
                    jlog("⚠️ required coaching action missing — scheduling fresh attempt")
                    return .failed(
                        outcome: .brainError,
                        failure: BrainFailure(
                            disposition: .temporary,
                            detail: "provider returned no required coaching tool call"),
                        work: work)
                }

                // Shared tail for every non-terminal tool call: replay the model's own call (verbatim
                // reasoning items when the provider needs them, or the plain call list otherwise),
                // append the tool's result, fold in any extra messages (e.g. an image), and advance
                // to the continuation phase for the next request in this same attempt.
                func appendToolContinuation(
                    toolCallId: String,
                    resultText: String,
                    extraMessages: [ChatMessage] = [],
                    newPhase: CoachingAttemptAuditEvent.RequestPhase
                ) {
                    if !response.outputItemsJSON.isEmpty {
                        turnMessages.append(.rawItems(response.outputItemsJSON))
                    } else {
                        turnMessages.append(.assistantToolCalls(response.rawToolCalls))
                    }
                    turnMessages.append(.init(role: .tool, text: resultText, toolCallId: toolCallId))
                    turnMessages.append(contentsOf: extraMessages)
                    requestPhase = newPhase
                    requestSequence += 1
                }

                switch call {
                case .captureScreen(let callID):
                    let screen = self.screen
                    let shot = await Self.captureScreen(using: screen, selecting: attempt.plan.screen)
                    if Task.isCancelled {
                        jlog("… attempt cancelled (stopped) after capture")
                        return .cancelled
                    }
                    if let shot {
                        jlog("👁 looking at your screen")
                        activity?.record(.screenViewed(imageBase64JPEG: shot.imageBase64))
                        if let text = shot.recognizedText {
                            jlog("🔤 read \(text.count(where: { $0 == "\n" }) + 1) lines of on-screen text")
                        }
                        work.screenObservation = [
                            .user(JarvisPrompts.Coach.captureResult(
                                recognizedText: shot.recognizedText
                            )),
                            .userImage(shot.imageBase64),
                        ]
                        appendToolContinuation(
                            toolCallId: callID,
                            resultText: JarvisPrompts.Coach.captureResult(
                                recognizedText: shot.recognizedText),
                            extraMessages: [.userImage(shot.imageBase64)],
                            newPhase: .captureScreenContinuation)
                    } else {
                        jlog("👁 screenshot failed")
                        activity?.record(.screenViewFailed)
                        work.screenObservation = [
                            .user(JarvisPrompts.Coach.earlierCaptureFailed),
                        ]
                        appendToolContinuation(
                            toolCallId: callID,
                            resultText: JarvisPrompts.Coach.captureFailed,
                            newPhase: .captureScreenContinuation)
                    }

                case .speak(let callID, let lines):
                    if Task.isCancelled {
                        jlog("… attempt cancelled (stopped) before speaking")
                        return .cancelled
                    }
                    jlog("💬 \(lines.joined(separator: " "))")
                    activity?.record(.tip(lines: lines))
                    overlay.render(
                        lines,
                        perLineSeconds: lines.map {
                            OverlayTiming.displaySeconds(for: $0, config: config)
                        })
                    turnMessages.append(.assistantToolCalls(response.rawToolCalls))
                    turnMessages.append(.init(
                        role: .tool,
                        text: JarvisPrompts.Coach.tipShown,
                        toolCallId: callID))
                    history.commit(turnMessages)
                    ledger.commit(through: delta.upTo)
                    return .completed(.spoke)

                case .staySilent:
                    if Task.isCancelled {
                        jlog("… attempt cancelled (stopped) before recording silence")
                        return .cancelled
                    }
                    jlog("… nothing useful to add, staying silent")
                    activity?.record(.stayedSilent)
                    commitIfWorthKeeping(turnMessages, deltaText: substantiveDeltaText)
                    ledger.commit(through: delta.upTo)
                    return .completed(.silentByModel)

                case .searchPrepNotes(let callID, let query):
                    if Task.isCancelled {
                        jlog("… attempt cancelled (stopped) before searching prep notes")
                        return .cancelled
                    }
                    // The tool is offered only when prepMaterial != nil (below), so a call here with
                    // it absent means a non-schema-enforced provider (a CLI protocol reconstructing
                    // calls from free-form prompt text) emitted one anyway — reject it rather than
                    // silently returning an empty result with a real-looking Activity entry implying
                    // prep material was actually checked.
                    guard let prepMaterial = attempt.prepMaterial else {
                        jlog("⚠️ search_prep_notes called without prep material configured — "
                             + "scheduling fresh attempt")
                        return .failed(
                            outcome: .brainError,
                            failure: BrainFailure(
                                disposition: .temporary,
                                detail: "search_prep_notes called without prep material configured"),
                            work: work)
                    }
                    let results = prepMaterial.search(query: query)
                    jlog("📎 searched prep notes for \"\(query)\" — \(results.count) match(es)")
                    activity?.record(.prepNotesSearched(query: query, matchCount: results.count))
                    // Mirrors capture_screen: if the very next request in this attempt fails, a
                    // fresh retry starts with this result already in hand — search is cheap to
                    // redo, but this still saves the model an extra tool-loop round-trip. Its own
                    // slot: replacing prepNotesObservation (not appending to the flat list) means a
                    // second search on a later retry supersedes the first's now-stale result instead
                    // of piling on top of it, while never touching screenObservation either way.
                    work.prepNotesObservation = .user(JarvisPrompts.Coach.prepNotesResult(results))
                    appendToolContinuation(
                        toolCallId: callID,
                        resultText: JarvisPrompts.Coach.prepNotesResult(results),
                        newPhase: .searchPrepNotesContinuation)
                }
            }

            jlog("⚠️ tool loop exhausted — scheduling fresh attempt")
            return .failed(
                outcome: .exhausted,
                failure: BrainFailure(
                    disposition: .temporary,
                    detail: "coaching tool loop exhausted"),
                work: work)
        }()

        await conversation.finish()
        if case .completed = result {
            startCompactionIfIdle(using: attempt.summarizer ?? attempt.brain)
        }
        return AttemptExecution(id: attemptID, result: result)
    }

    private func commitIfWorthKeeping(_ turn: [ChatMessage], deltaText: String) {
        guard !deltaText.isEmpty || turn.count > 1 else { return }
        history.commit(turn)
    }

    /// Screen capture is an OS-bound synchronous edge, so run it off the cooperative executor.
    /// Cancellation asks the capture adapter to terminate its helper, then waits for `capture()` to
    /// return so the attempt cannot outlive cleanup of screen-derived files.
    private static func captureScreen(
        using screen: ScreenCapturing,
        selecting selection: ScreenCaptureSelection
    ) async -> ScreenSnapshot? {
        let capture = Task.detached(priority: .userInitiated) { () -> ScreenSnapshot? in
            guard !Task.isCancelled else { return nil }
            return screen.capture(selection)
        }
        return await withTaskCancellationHandler {
            // Await the producer itself. A cancelled AsyncStream consumer returns immediately and
            // would let conversation/session drain race the helper's exit and JPEG cleanup.
            await capture.value
        } onCancel: {
            capture.cancel()
            screen.cancelCapture()
        }
    }

    // MARK: - History compaction

    /// Compaction is auxiliary, so it runs off the attempt path: awaiting it here would spend its
    /// whole budget as dead air, batching newly finalized speech behind a summary nobody is waiting
    /// for. One run at a time — two overlapping runs each replace `0..<prefixCount`, so the second
    /// would destroy the first's summary along with real turns. A skipped or failed run simply
    /// retries from a fresh prefix after the next completed attempt.
    func startCompactionIfIdle(using client: BrainClient) {
        // Check the threshold before spawning: most completed attempts are nowhere near it, and a
        // task per attempt would be pure churn on the shared executor.
        guard history.estimatedTokens > config.historyCompactionTokenThreshold else { return }
        runnerLock.lock()
        // Stop is final. A turn suspended in `conversation.finish()` when teardown ran resumes after
        // `cancelBackgroundWork` already looked for a task, and would otherwise start a fresh
        // provider request that nothing is left to drain.
        guard !backgroundWorkStopped else {
            runnerLock.unlock()
            return
        }
        guard !isCompacting else {
            // Coalesce rather than drop. An attempt landing mid-summary is also the attempt whose
            // fresh OCR can invalidate that summary, so without this the rejected pass and the
            // skipped request cancel each other out and history stays over the threshold.
            compactionRequested = true
            runnerLock.unlock()
            return
        }
        isCompacting = true
        compactionRequested = false
        let task = Task.detached(priority: .utility) { [self] in
            await runCompactionPasses(using: client)
        }
        compactionTask = task
        runnerLock.unlock()
    }

    /// Run compaction until nothing more is pending, so a pass that ends without compacting — a
    /// summary rejected as stale, or one skipped while another ran — is retried instead of waiting
    /// for a further completed attempt.
    private func runCompactionPasses(using client: BrainClient) async {
        while true {
            await compactIfNeeded(using: client)
            let overThreshold = history.estimatedTokens > config.historyCompactionTokenThreshold
            let runAgain: Bool = runnerLock.withLock {
                guard compactionRequested, overThreshold, !Task.isCancelled else {
                    isCompacting = false
                    compactionTask = nil
                    return false
                }
                compactionRequested = false
                return true
            }
            if !runAgain { return }
        }
    }

    /// Cancel background work that must not outlive the session, handing back the task so teardown
    /// can drain it before sealing the audit.
    ///
    /// Compaction runs off the attempt path, so `TurnTaskBox` does not own it. Without this a
    /// summary keeps a provider process alive and billing after Stop, and can still be writing when
    /// the session audit closes.
    @discardableResult
    func cancelBackgroundWork() -> Task<Void, Never>? {
        runnerLock.lock()
        backgroundWorkStopped = true
        compactionRequested = false
        let task = compactionTask
        compactionTask = nil
        runnerLock.unlock()
        task?.cancel()
        return task
    }

    /// Auxiliary compaction fails soft and never counts against provider route health.
    private func compactIfNeeded(using client: BrainClient) async {
        guard history.estimatedTokens > config.historyCompactionTokenThreshold else { return }
        guard let (oldest, count, revision) = history.compactionPrefix() else { return }
        do {
            let response = try await client.respond(
                messages: [
                    .system(JarvisPrompts.HistorySummary.system),
                    .user(JarvisPrompts.HistorySummary.input(oldest)),
                ],
                tools: [],
                toolChoice: .auto)
            guard let summary = response.outputText, !summary.isEmpty else {
                jlog("… memory compaction returned nothing — keeping full history for now")
                return
            }
            // A summary that lands as teardown cancels must not mutate history on the way out: the
            // session is over and the provider may simply have won the race.
            guard !Task.isCancelled else { return }
            guard history.compact(prefixCount: count, summary: summary, revision: revision) else {
                jlog("… discarded a summary written against superseded screen text — will retry later")
                return
            }
            jlog("… condensed session memory to ~\(history.estimatedTokens) tokens")
        } catch {
            jlog("… memory compaction failed (will retry later): \(error.localizedDescription)")
        }
    }
}
