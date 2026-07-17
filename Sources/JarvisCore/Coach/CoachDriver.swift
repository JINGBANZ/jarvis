import Foundation

/// The event loop. On a trigger, calls the brain with the timestamped transcript + timing context
/// and the tool set, and routes tool calls (capture_screen, speak, stay_silent). Response judgment
/// lives in the model. Manual, silence, and locally observed visual-change triggers arrive with a
/// fresh capture; ordinary speech leaves the decision to the model's general screen-freshness policy.
/// There is no cooldown or rate cap: every
/// substantive utterance (from either speaker — an interviewer question can draw a proactive tip)
/// reaches the brain and the brain decides whether it has anything worth saying (the system prompt
/// carries that restraint). The one client-side skip is the substance gate: a turn-end whose delta
/// is pure back-channel filler ("Hmm", "嗯") never becomes a request — see `TurnSubstance`.
///
/// Session memory is CLIENT-managed (`CoachHistory`): each request is `[system] + history + turn`,
/// built append-only for prompt-cache hits, and compacted into a summary when it grows past the
/// threshold. There is no server-side conversation object — no lock to hold, nothing to dangle.
///
/// `@unchecked Sendable` is justified: the only mutable state is guarded by a lock (or lives in the
/// internally-synchronized `CoachHistory`), and the injected dependencies are each either immutable
/// or internally synchronized. A single in-flight turn is enforced by `claimOrPend()` — an atomic
/// check-then-set taken before any `await` — so two concurrent triggers can't run overlapping turns;
/// the second is coalesced into the first.
public final class CoachDriver: @unchecked Sendable {
    private let config: Config
    private let transcript: RollingTranscript
    private let brain: BrainClient
    /// Writes the compaction summaries — typically a cheaper model than the coach (see AppDelegate).
    /// Nil falls back to `brain`, so tests and minimal callers need not wire one.
    private let summarizer: BrainClient?
    private let screen: ScreenCapturing
    private let overlay: OverlayRendering
    private let clock: Clock
    private let sessionStart: TimeInterval
    /// Acknowledges snapshots the coach can use: immediately for ordinary captures, and only after
    /// the first brain request succeeds for a monitor-supplied stable change.
    private let onScreenCaptured: (@Sendable (ScreenSnapshot) -> Void)?
    /// Re-arms a stable monitor candidate when its first brain request did not succeed.
    private let onScreenCaptureRejected: (@Sendable () -> Void)?
    private let history = CoachHistory()

    /// Safety backstop against a pathological model that loops on capture_screen forever.
    private let maxToolIterations = 4

    private let stateLock = NSLock()
    private var isHandling = false
    /// Number of transcript lines already sent to the brain. Each turn sends `lines[sentCount...]`
    /// and advances this ONLY after the input reached the server, so a failed turn re-sends its speech.
    private var sentCount = 0
    private struct AuditedMonitorSnapshotID: Hashable {
        let hash: UInt64
        let byteCount: Int
    }
    /// Monitor retries reuse the same in-memory image. Persist it before the first network attempt,
    /// then keep a content-free ID so later attempts remain auditable without duplicating JPEGs.
    private var auditedMonitorSnapshots: Set<AuditedMonitorSnapshotID> = []
    // FNV-1a constants. The hash is only a content-free, in-memory retry identity; byte count is
    // included as an additional collision discriminator and no screen-derived digest is persisted.
    private static let fnv1a64OffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnv1a64Prime: UInt64 = 1_099_511_628_211
    private struct TurnRequest: Sendable {
        let reason: TriggerReason
        /// A stable snapshot supplied by the local monitor. Using this exact image avoids a second
        /// capture race/failure between detecting a change and sending it to the brain.
        let suppliedSnapshot: ScreenSnapshot?
    }

    /// A trigger that arrived while a turn was running — coalesced into the running turn's follow-up so
    /// nothing is dropped and turns don't pile up. Speech rides along via the sent-index; if several
    /// trigger reasons compete, keep the one carrying the strongest behavior (manual request, then
    /// visual change, then silence) rather than losing a required fresh-screen capture.
    private var pendingTrigger: TurnRequest?

    public init(config: Config, transcript: RollingTranscript,
                brain: BrainClient, summarizer: BrainClient? = nil,
                screen: ScreenCapturing, overlay: OverlayRendering, clock: Clock,
                onScreenCaptured: (@Sendable (ScreenSnapshot) -> Void)? = nil,
                onScreenCaptureRejected: (@Sendable () -> Void)? = nil) {
        self.config = config
        self.transcript = transcript
        self.brain = brain
        self.summarizer = summarizer
        self.screen = screen
        self.overlay = overlay
        self.clock = clock
        self.sessionStart = clock.now()
        self.onScreenCaptured = onScreenCaptured
        self.onScreenCaptureRejected = onScreenCaptureRejected
    }

    // Synchronous lock accessors — NSLock can't be held across an `await`, so all critical sections
    // live in non-async helpers.
    private func currentSentCount() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }; return sentCount
    }
    /// Advance the read position (forward only) once the input has reached the brain.
    private func advanceSentCount(to upTo: Int) {
        stateLock.lock(); if upTo > sentCount { sentCount = upTo }; stateLock.unlock()
    }

    /// Atomically claim the single in-flight slot, OR (if busy) record the trigger as pending. One
    /// critical section so a trigger can never slip between "am I busy?" and "set pending" and be lost.
    /// Returns true if this call now owns the turn loop. The highest-priority pending reason is kept;
    /// coalesced speech rides along regardless via the transcript delta.
    private func claimOrPend(_ request: TurnRequest) -> Bool {
        var rejectedDisplacedMonitorSnapshot = false
        var rejectedIncomingMonitorSnapshot = false
        stateLock.lock()
        if isHandling {
            if let pendingTrigger {
                let incomingPriority = Self.coalescingPriority(request)
                let pendingPriority = Self.coalescingPriority(pendingTrigger)
                if incomingPriority > pendingPriority
                    || (incomingPriority == pendingPriority
                        && request.reason == .screenChanged
                        && request.suppliedSnapshot != nil) {
                    // A manual hint can supersede a queued monitor turn because it takes its own
                    // fresh screenshot. Re-arm the displaced stable candidate in case that capture
                    // fails; otherwise the detector would wait forever for an acknowledgement that
                    // can no longer arrive. A newer monitor snapshot replacing an older one needs no
                    // rejection because the replacement itself still carries the visual update.
                    rejectedDisplacedMonitorSnapshot = pendingTrigger.suppliedSnapshot != nil
                        && request.reason != .screenChanged
                    self.pendingTrigger = request
                } else {
                    // The supplied monitor snapshot was not queued (currently only because a manual
                    // hint is already pending). Tell the detector it lost this coalescing race so it
                    // can keep retrying until either that hint observes a fresh screen or the visual
                    // turn eventually gets a slot.
                    rejectedIncomingMonitorSnapshot = request.suppliedSnapshot != nil
                }
            } else {
                pendingTrigger = request
            }
            stateLock.unlock()
            if rejectedDisplacedMonitorSnapshot || rejectedIncomingMonitorSnapshot {
                onScreenCaptureRejected?()
            }
            return false
        }
        isHandling = true
        stateLock.unlock()
        return true
    }

    /// Atomically take the next pending trigger (keeping the slot) OR release the slot. One critical
    /// section so a trigger arriving exactly as a turn finishes is never orphaned.
    private func finishTurnOrTakeNext() -> TurnRequest? {
        stateLock.lock(); defer { stateLock.unlock() }
        if let next = pendingTrigger { pendingTrigger = nil; return next }   // keep isHandling = true
        isHandling = false
        return nil
    }

    @discardableResult
    public func handleTrigger(_ reason: TriggerReason) async -> TurnOutcome {
        await handle(TurnRequest(reason: reason, suppliedSnapshot: nil))
    }

    /// Entry point for the local visual monitor. The stable snapshot it observed is the exact image
    /// logged and sent; CoachDriver does not take a second screenshot that could fail or race ahead.
    @discardableResult
    public func handleScreenChange(_ snapshot: ScreenSnapshot) async -> TurnOutcome {
        await handle(TurnRequest(reason: .screenChanged, suppliedSnapshot: snapshot))
    }

    /// Audio turn carrying a stable monitor snapshot. The speech request was already going to happen,
    /// so attaching this image gives the model current visual context without an extra coach request.
    @discardableResult
    public func handleTurnEnd(screenSnapshot: ScreenSnapshot) async -> TurnOutcome {
        await handle(TurnRequest(reason: .turnEnd, suppliedSnapshot: screenSnapshot))
    }

    private func handle(_ request: TurnRequest) async -> TurnOutcome {
        // Single-in-flight, but we COALESCE rather than drop: a trigger arriving while a turn runs is
        // recorded as pending and picked up by the running turn when it finishes — so nothing is lost
        // and turns can't pile up. The batched speech rides along automatically via the sent-index.
        guard claimOrPend(request) else {
            jlog("… busy; batching this \(request.reason) into the running turn")
            return .busy
        }
        var current = request
        var outcome: TurnOutcome = .silentByModel
        while true {
            outcome = await runTurn(current)
            guard let next = finishTurnOrTakeNext() else { return outcome }
            current = next
        }
    }

    /// Run one coaching turn for `request`.
    private func runTurn(_ request: TurnRequest) async -> TurnOutcome {
        let reason = request.reason
        // Stop may have cancelled this turn before it got the slot.
        if Task.isCancelled { jlog("… turn cancelled (stopped) before handling"); return .cancelled }

        // Turn-end already shows up as the "🗣 heard:" line from the transcriber; only the silence
        // and screen-only triggers need their own markers.
        if case .silence(let secs) = reason { jlog("🤫 quiet for \(Int(secs))s") }
        if reason == .screenChanged {
            jlog("🖥 stable screen change detected — checking current context")
        }

        let now = clock.now()
        let ctx = TriggerContext(reason: reason, sessionElapsedSeconds: now - sessionStart)

        // A hotkey trigger leaves no "🗣 heard:" line (the user pressed a key, didn't speak), so record
        // it — with the synthetic request we pre-fill as the user's message — so the activity viewer
        if reason == .manualHint, let line = ctx.promptLine { jlog("⌨️ hint shortcut — \(line)") }

        // The delta: only the lines the brain hasn't seen yet (the rest live in `history`).
        let delta = transcript.renderFrom(index: currentSentCount())

        // The substance gate: a turn-end whose delta is pure back-channel filler (from EITHER
        // speaker) or empty never becomes a request — filler can't produce a tip, and the request
        // would re-bill the whole working set just to decide "stay silent". The unsent lines ride
        // along on the next substantive turn (sentCount only advances on a send); silence,
        // screen-change, and manual-hint triggers always go through. Logged so gate misfires are auditable.
        if reason == .turnEnd && request.suppliedSnapshot == nil
            && !delta.lines.contains(where: TurnSubstance.isSubstantive) {
            // Log WHAT was skipped (not just that a skip happened) so a gate misfire — a real remark
            // wrongly classified as filler — is visible in the activity viewer, not silent.
            let preview = delta.lines.isEmpty
                ? "nothing new"
                : String(delta.lines.map(\.text).joined(separator: " · ").prefix(80))
            jlog("… skipped as filler (\(preview)) — not calling the brain")
            return .skippedFillerOnly
        }

        // Every request this turn = [system] + session memory + this turn's messages. The base is
        // snapshotted once, so the prefix is stable across the turn's tool-loop iterations (and
        // across turns, history being append-only — that's what keeps the prompt cache hitting).
        let historyBase: [ChatMessage] = [.system(coachSystemPrompt)] + history.snapshot()
        // New speech (when there is any) followed by the trigger note (when there is one — a
        // turn-end has none, the stamped delta already carries that signal). Never both empty:
        // an empty turn-end delta is gated above, and silence/screen-change/manual-hint have a note.
        let userText = [delta.text.isEmpty ? nil : "New since last turn:\n\(delta.text)",
                        ctx.promptLine].compactMap { $0 }.joined(separator: "\n\n")
        var turnMessages: [ChatMessage] = [.user(userText)]
        var pendingMonitorSnapshot: ScreenSnapshot?
        var pendingMonitorSnapshotWasAudited = false
        var pendingOrdinarySnapshot: ScreenSnapshot?

        // Harness-owned fresh visuals: manual requests, silence checks, and visual-monitor changes
        // capture HERE and inject the image + OCR into THIS first request. Ordinary speech is not
        // phrase-matched; the model applies the general screen-freshness policy and can call the
        // capture tool when the meaning of the turn says the screen may have changed.
        if request.suppliedSnapshot != nil || Self.needsFreshScreen(reason: reason) {
            let shot: ScreenSnapshot?
            if let suppliedSnapshot = request.suppliedSnapshot {
                if Task.isCancelled {
                    jlog("… turn cancelled (stopped) before accepting screen change")
                    return .cancelled
                }
                shot = suppliedSnapshot
                pendingMonitorSnapshot = suppliedSnapshot
            } else {
                shot = await captureScreen()
                pendingOrdinarySnapshot = shot
            }
            if Task.isCancelled { jlog("… turn cancelled (stopped) after capture"); return .cancelled }
            if let shot {
                turnMessages.append(.user(Self.freshSnapshotBlock))
                turnMessages.append(.userImage(shot.imageBase64))
                // OCR sidecar: the same window as exact text, so the model reads code instead of
                // deciphering pixels. Rides as its own user message — there's no tool result to
                // carry it on this pre-injected path.
                if let text = shot.recognizedText {
                    turnMessages.append(.user(Self.recognizedTextBlock(text)))
                }
            }
        }

        // Force `speak` ONLY for an explicit manual hint; audio-driven turns use `.required` — SOME
        // tool, the model's pick (speak, look at the screen, or stay_silent). Requiring a call is what
        // keeps a stay-quiet decision from leaking free deliberation text into the stored history.
        let turnToolChoice: ToolChoice = (reason == .manualHint) ? .force(speakTool.name) : .required

        jlog("💭 thinking…")

        var committed = false
        var iterations = 0
        while iterations < maxToolIterations {
            iterations += 1
            if let snapshot = pendingMonitorSnapshot, !pendingMonitorSnapshotWasAudited {
                guard auditMonitorSnapshotBeforeSend(snapshot) else {
                    onScreenCaptureRejected?()
                    jlog("Jarvis coach: aborting screen-change request because its audit copy "
                         + "could not be persisted")
                    return .screenAuditError
                }
                pendingMonitorSnapshotWasAudited = true
            }
            let response: BrainResponse
            do {
                response = try await brain.respond(messages: historyBase + turnMessages,
                                                   tools: coachTools, toolChoice: turnToolChoice)
            } catch {
                if pendingMonitorSnapshot != nil { onScreenCaptureRejected?() }
                // A cancellation (barge-in / Stop) is expected — report it quietly, not as a failure.
                if Task.isCancelled { jlog("… turn cancelled (interrupted)"); return .cancelled }
                jlog("Jarvis coach: brain request failed on \(reason): \(error.localizedDescription)")
                // Speech already marked sent (a later-iteration failure) must not vanish from memory —
                // commit what this turn accumulated. A first-request failure commits nothing; the
                // un-advanced sentCount re-sends the delta next turn instead.
                if committed {
                    commitIfWorthKeeping(turnMessages, deltaText: delta.text, reason: reason)
                }
                return .brainError
            }

            // The input provably reached the server — NOW mark the delta as sent.
            if !committed { advanceSentCount(to: delta.upTo); committed = true }

            if Task.isCancelled {
                if pendingMonitorSnapshot != nil { onScreenCaptureRejected?() }
                jlog("… turn cancelled (stopped) mid-think")
                commitIfWorthKeeping(turnMessages, deltaText: delta.text, reason: reason)
                return .cancelled
            }

            // A monitor snapshot is acknowledged only after its first request succeeds. Until this
            // point the detector retains its prior baseline, so a transport failure can retry the
            // same stable question/code instead of silently losing it.
            if let snapshot = pendingMonitorSnapshot {
                onScreenCaptured?(snapshot)
                pendingMonitorSnapshot = nil
            }
            if let snapshot = pendingOrdinarySnapshot {
                onScreenCaptured?(snapshot)
                pendingOrdinarySnapshot = nil
            }

            // No tool call → a TRUNCATED run (zero items because reasoning blew the token cap), or a
            // model ignoring `tool_choice: required`. Treat the latter as silence — rendering nothing
            // is the safe interpretation. Either way the sent delta must land in memory.
            guard let call = response.toolCalls.first else {
                commitIfWorthKeeping(turnMessages, deltaText: delta.text, reason: reason)
                if let reasonText = response.incompleteReason {
                    jlog("⚠️ response truncated (\(reasonText)) — not deliberate silence")
                    return .truncated
                }
                jlog("… nothing useful to add, staying silent")
                await compactIfNeeded()
                return .silentByModel
            }

            switch call {
            case .captureScreen(let callId):
                let shot = await captureScreen()
                // Stop may have fired during the (un-cancellable, detached) capture. Bail before
                // emitting: otherwise this screenshot — and the reasoning that follows — would be
                // logged into whatever session is now current (a Start rotates the log mid-turn).
                if Task.isCancelled {
                    jlog("… turn cancelled (stopped) after capture")
                    history.commit(turnMessages)
                    return .cancelled
                }
                // Thread the call + its result into this turn's messages; the next iteration's
                // request carries them (and they land in history at commit, where the screenshot
                // becomes a text stub — only the OCR text outlives the turn). The OCR sidecar
                // travels in the tool-result text, right next to the image. The model's output goes
                // back WHOLE and verbatim — reasoning then function_call, item ids intact, the
                // canonical `input.push(...response.output)` loop: pairing a raw reasoning item with
                // a rebuilt, id-less call trips the provider's reasoning/function-call linkage
                // validation, and dropping the reasoning makes the model re-reason from scratch.
                // (`CoachHistory.commit` converts this back to the proven id-less call and drops the
                // reasoning — later turns don't need it.)
                if !response.outputItemsJSON.isEmpty {
                    turnMessages.append(.rawItems(response.outputItemsJSON))
                } else {
                    // No raw bytes to replay (a scripted test brain, or a response whose raw output
                    // failed to re-serialize): fall back to the synthetic id-less call so the tool
                    // result below never orphans.
                    turnMessages.append(.assistantToolCalls(response.rawToolCalls))
                }
                if let shot {
                    pendingOrdinarySnapshot = shot
                    turnMessages.append(.init(role: .tool, text: Self.captureResultText(shot), toolCallId: callId))
                    turnMessages.append(.userImage(shot.imageBase64))
                } else {
                    turnMessages.append(.init(role: .tool, text: "screenshot failed", toolCallId: callId))
                }
                continue // let the model reason over the image

            case .speak(let callId, let lines):
                // Last gate before side effects: a turn cancelled by Stop (or a Stop→Start that
                // rotated the session) must not render a stale tip or log into the new session.
                // This is the "speak after Stop" guard the TurnTaskBox relies on.
                if Task.isCancelled { jlog("… turn cancelled (stopped) before speaking"); return .cancelled }
                jlog("💬 \(lines.joined(separator: " "))")
                let perLine = lines.map { OverlayTiming.displaySeconds(for: $0, config: config) }
                overlay.render(lines, perLineSeconds: perLine)
                // Close the call locally — we own the history, so no follow-up round trip is needed.
                turnMessages.append(.assistantToolCalls(response.rawToolCalls))
                turnMessages.append(.init(role: .tool, text: "shown to the user", toolCallId: callId))
                history.commit(turnMessages)
                await compactIfNeeded()
                return .spoke

            case .staySilent:
                // The model's explicit stay-quiet decision. Deliberately NOT recorded: the call and
                // its non-answer would only bloat every later request — silence needs no memory.
                jlog("… nothing useful to add, staying silent")
                commitIfWorthKeeping(turnMessages, deltaText: delta.text, reason: reason)
                await compactIfNeeded()
                return .silentByModel
            }
        }
        jlog("… tool loop exhausted without speaking")
        history.commit(turnMessages)   // captures + speech stay in memory even on the backstop path
        await compactIfNeeded()
        return .exhausted
    }

    /// A monitor-only request that produced no tip is an acknowledged freshness probe, not useful
    /// conversation memory. Keeping its OCR and trigger note would make every later request larger
    /// during active typing. Speech, spoken tips, and non-monitor tool turns retain their existing
    /// history behavior.
    private func commitIfWorthKeeping(_ turn: [ChatMessage], deltaText: String,
                                      reason: TriggerReason) {
        guard !deltaText.isEmpty || (reason != .screenChanged && turn.count > 1) else { return }
        history.commit(turn)
    }

    private static func needsFreshScreen(reason: TriggerReason) -> Bool {
        switch reason {
        case .manualHint, .silence, .screenChanged:
            return true
        case .turnEnd:
            return false
        }
    }

    private static func coalescingPriority(_ request: TurnRequest) -> Int {
        if request.suppliedSnapshot != nil { return 2 }
        return switch request.reason {
        case .turnEnd: 0
        case .silence: 1
        case .screenChanged: 2
        case .manualHint: 3
        }
    }

    /// ScreenCaptureCLI shells out to `screencapture` and blocks for 100s of ms; run it off the
    /// cooperative pool. The image is logged immediately, but the caller acknowledges it to the
    /// visual monitor only after the brain request carrying it succeeds.
    private func captureScreen() async -> ScreenSnapshot? {
        let screen = self.screen
        let shot = await Task.detached(priority: .userInitiated, operation: { screen.capture() }).value
        guard !Task.isCancelled else { return shot }

        if let shot {
            acceptScreenSnapshot(shot)
        } else {
            jlog("👁 screenshot failed")
        }
        return shot
    }

    /// Persists the exact snapshot the brain will consume. Monitor acknowledgement is deliberately a
    /// separate success-only callback; ordinary captures acknowledge immediately after this call.
    private func acceptScreenSnapshot(_ shot: ScreenSnapshot) {
        jlog("👁 looking at your screen", image: shot.imageBase64)
        if let text = shot.recognizedText {
            jlog("🔤 read \(text.count(where: { $0 == "\n" }) + 1) lines of on-screen text")
        }
    }

    /// The traffic log redacts image bytes, so the owner-only activity log must receive a monitor
    /// screenshot before the request can leave the machine. A successful response separately
    /// acknowledges the monitor baseline; transport failure keeps the candidate retryable.
    private func auditMonitorSnapshotBeforeSend(_ shot: ScreenSnapshot) -> Bool {
        let id = Self.auditedSnapshotID(for: shot.imageBase64)
        stateLock.lock()
        let alreadyAudited = auditedMonitorSnapshots.contains(id)
        stateLock.unlock()
        if !alreadyAudited {
            guard jlogSynchronously(
                "👁 looking at your screen", image: shot.imageBase64
            ) else { return false }
            stateLock.lock(); auditedMonitorSnapshots.insert(id); stateLock.unlock()
            if let text = shot.recognizedText {
                jlog("🔤 read \(text.count(where: { $0 == "\n" }) + 1) lines of on-screen text")
            }
        } else {
            jlog("👁 reusing previously logged screen capture for retry")
        }
        return true
    }

    private static func auditedSnapshotID(for base64: String) -> AuditedMonitorSnapshotID {
        var hash = fnv1a64OffsetBasis
        var byteCount = 0
        for byte in base64.utf8 {
            hash ^= UInt64(byte)
            hash &*= fnv1a64Prime
            byteCount += 1
        }
        return AuditedMonitorSnapshotID(hash: hash, byteCount: byteCount)
    }
    private static let freshSnapshotBlock = """
    Fresh point-in-time screen capture taken for this turn. It shows the screen only at capture time
    and may become stale after any typing, navigation, or newly displayed question.
    """

    /// The capture_screen tool-result text: the OCR sidecar rides here when present, so exact text
    /// and the image arrive as one result the model reasons over together.
    private static func captureResultText(_ shot: ScreenSnapshot) -> String {
        guard let text = shot.recognizedText else { return "fresh point-in-time screenshot captured" }
        return "fresh point-in-time screenshot captured\n\n\(recognizedTextBlock(text))"
    }

    /// Framed so the model treats OCR as a reading aid, not gospel — recognition mangles the odd
    /// identifier, and the screenshot stays the ground truth to verify against.
    private static func recognizedTextBlock(_ text: String) -> String {
        """
        Text recognized on this point-in-time captured window (on-device OCR — may contain errors; \
        the same screenshot image is ground truth, and both may become stale after the screen changes):
        \(text)
        """
    }

    // MARK: - History compaction

    /// When the session memory outgrows the threshold, condense its oldest span into a short summary
    /// (via `summarizer`, falling back to the coach brain). Runs while still holding the turn slot —
    /// a concurrent trigger just coalesces, so there's no compaction/turn race — and fails soft: on
    /// any error the full history simply rides along until the next attempt.
    private func compactIfNeeded() async {
        guard history.estimatedTokens > config.historyCompactionTokenThreshold else { return }
        guard let (oldest, count) = history.compactionPrefix() else { return }
        do {
            let response = try await (summarizer ?? brain).respond(
                messages: [.system(Self.summaryInstructions), .user(Self.renderForSummary(oldest))],
                tools: [], toolChoice: .auto)
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

    /// Flatten history messages into plain text for the summarizer (it needs the story, not the
    /// tool-call wire format).
    private static func renderForSummary(_ messages: [ChatMessage]) -> String {
        messages.map { m in
            if let calls = m.toolCalls {
                return calls.map { "coach called \($0.name)" }.joined(separator: "\n")
            }
            if m.imageBase64JPEG != nil { return "[screenshot]" }
            let text = m.text ?? ""
            return m.role == .tool ? "tool result: \(text)" : text
        }.joined(separator: "\n")
    }
}

/// The terminal outcome of a coaching turn — surfaced so every "quiet" path is observable instead
/// of a silent `return`. Tuning VAD / silence-backoff thresholds depends on knowing WHICH of these
/// fired.
public enum TurnOutcome: Sendable, Equatable {
    case spoke            // rendered a coaching tip
    case silentByModel    // model deliberately stayed quiet (stay_silent, or no tool call)
    case skippedFillerOnly // turn-end delta was pure back-channel filler — brain not called (cost gate)
    case truncated        // response cut off by the token cap (NOT a real silence decision)
    case busy             // a turn was in flight; this trigger was coalesced into it (not dropped)
    case cancelled        // Stop cancelled the turn
    case brainError       // the brain request threw (401/429/network)
    case screenAuditError // request was aborted because its screenshot could not be persisted
    case exhausted        // ran the tool loop to the cap without a terminal speak
}
