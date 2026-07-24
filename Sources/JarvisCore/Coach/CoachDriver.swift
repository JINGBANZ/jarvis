import Foundation

/// The event loop. On a trigger, calls the brain with the timestamped transcript + timing context
/// and the tool set, and routes tool calls (capture_screen, speak, stay_silent). All judgment lives
/// in the model — including when to stay quiet and when to answer a direct address — so this just
/// wires events to tool calls. There is no cooldown or rate cap: every substantive utterance (from
/// either speaker — an interviewer question can draw a proactive tip) reaches the brain and the brain
/// decides whether it has anything worth saying (the system prompt carries that restraint). The one
/// client-side skip is the substance gate: a turn-end whose delta is pure back-channel filler
/// ("Hmm", "嗯") never becomes a request — see `TurnSubstance`.
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
    private let screen: ScreenCapturing
    private let overlay: OverlayRendering
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let history = CoachHistory()

    /// Safety backstop against a pathological model that loops on capture_screen forever.
    private let maxToolIterations = 4

    private let stateLock = NSLock()
    /// The coach, its cheaper compaction model, and its provider-specific failure policies move
    /// together. A turn snapshots this before any awaited work, so a Settings change cannot split
    /// its manual capture or model tool loop across providers; the replacement starts next turn.
    private struct BrainConfiguration {
        let revision: UInt
        let brain: BrainClient
        let provider: BrainProvider?
        let summarizer: BrainClient?
        let onFailure: (@MainActor @Sendable (BrainFailure) -> Void)?
        let onChangeApplied: (@Sendable (BrainProvider?, BrainProvider?) -> Void)?
        let onFallback: (@Sendable (BrainProvider?, BrainProvider?) -> Void)?
    }
    private var brainConfiguration: BrainConfiguration
    /// The previous active configuration. A replacement keeps it until the replacement itself
    /// completes one non-truncated terminal turn, making a Settings change a transactional cutover.
    private var fallbackBrainConfiguration: BrainConfiguration?
    private var isHandling = false
    /// Number of transcript lines already sent to the brain. Each turn sends `lines[sentCount...]`
    /// and advances this ONLY after the input reached the server, so a failed turn re-sends its speech.
    private var sentCount = 0
    /// A trigger that arrived while a turn was running — coalesced into the running turn's follow-up so
    /// nothing is dropped and turns don't pile up. The first such trigger is kept and the batched
    /// speech rides along via the sent-index, so a later trigger needn't displace it.
    private var pendingTrigger: TriggerReason?
    /// Latched only when the app classifies a provider failure as terminal. It prevents pending or
    /// newly arriving triggers from issuing another request while the app's main-actor stop is still
    /// being scheduled. A temporary missed turn never touches this latch.
    private var terminalBrainFailure = false

    public init(config: Config, transcript: RollingTranscript,
                brain: BrainClient, brainProvider: BrainProvider? = nil,
                summarizer: BrainClient? = nil,
                screen: ScreenCapturing, overlay: OverlayRendering, clock: Clock,
                onBrainFailure: (@MainActor @Sendable (BrainFailure) -> Void)? = nil) {
        self.config = config
        self.transcript = transcript
        self.screen = screen
        self.overlay = overlay
        self.clock = clock
        self.brainConfiguration = BrainConfiguration(
            revision: 0, brain: brain, provider: brainProvider, summarizer: summarizer,
            onFailure: onBrainFailure, onChangeApplied: nil, onFallback: nil)
        self.sessionStart = clock.now()
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

    /// Replace only the model layer of a running coach. The transcript, sent position, history,
    /// trigger queue, overlays, and audio pipeline stay intact. If a turn is already in flight it
    /// finishes with its snapshotted configuration; the replacement owns the next turn. The last
    /// working configuration remains a fallback until the replacement completes one non-truncated
    /// terminal turn.
    public func updateBrain(
        _ brain: BrainClient,
        provider: BrainProvider? = nil,
        summarizer: BrainClient? = nil,
        onBrainFailure: (@MainActor @Sendable (BrainFailure) -> Void)? = nil,
        onBrainChangeApplied: (@Sendable (BrainProvider?, BrainProvider?) -> Void)? = nil,
        onBrainFallback: (@Sendable (BrainProvider?, BrainProvider?) -> Void)? = nil
    ) {
        stateLock.lock()
        // Several Settings edits can land before another coaching turn. Keep the original active
        // configuration as the fallback rather than replacing it with an untried intermediate one.
        if fallbackBrainConfiguration == nil {
            fallbackBrainConfiguration = brainConfiguration
        }
        brainConfiguration = BrainConfiguration(
            revision: brainConfiguration.revision &+ 1,
            brain: brain, provider: provider, summarizer: summarizer,
            onFailure: onBrainFailure, onChangeApplied: onBrainChangeApplied,
            onFallback: onBrainFallback)
        // A provider change is a recovery path if the former provider failed just as Settings was
        // changed. Any failure from the superseded revision is ignored below instead of re-latching.
        terminalBrainFailure = false
        stateLock.unlock()
    }

    private func currentBrainConfiguration() -> BrainConfiguration {
        stateLock.lock(); defer { stateLock.unlock() }; return brainConfiguration
    }

    /// Commit a successful cutover only if this is still the active revision. A turn on a provider
    /// superseded while it was in flight must not discard the newer replacement's fallback.
    private func confirmBrainConfiguration(_ revision: UInt) {
        var callback: (@Sendable (BrainProvider?, BrainProvider?) -> Void)?
        var previousProvider: BrainProvider?
        var activeProvider: BrainProvider?
        stateLock.lock()
        if brainConfiguration.revision == revision,
           let fallback = fallbackBrainConfiguration {
            callback = brainConfiguration.onChangeApplied
            previousProvider = fallback.provider
            activeProvider = brainConfiguration.provider
            fallbackBrainConfiguration = nil
        }
        stateLock.unlock()
        callback?(previousProvider, activeProvider)
    }

    /// Restore the previous active configuration when an unconfirmed replacement fails. The restored
    /// clients get a fresh revision so stale failures cannot match them through an ABA-style race.
    private func restoreFallback(
        for failing: BrainConfiguration
    ) -> (configuration: BrainConfiguration,
          callback: (@Sendable (BrainProvider?, BrainProvider?) -> Void)?)? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard brainConfiguration.revision == failing.revision,
              let fallback = fallbackBrainConfiguration else { return nil }
        let restored = BrainConfiguration(
            revision: brainConfiguration.revision &+ 1,
            brain: fallback.brain, provider: fallback.provider, summarizer: fallback.summarizer,
            onFailure: fallback.onFailure, onChangeApplied: fallback.onChangeApplied,
            onFallback: fallback.onFallback)
        brainConfiguration = restored
        fallbackBrainConfiguration = nil
        terminalBrainFailure = false
        return (restored, failing.onFallback)
    }

    /// Atomically claim the single in-flight slot, OR (if busy) record the trigger as pending. One
    /// critical section so a trigger can never slip between "am I busy?" and "set pending" and be lost.
    /// Returns whether this call owns the loop, was queued behind it, or arrived after a terminal
    /// provider failure. The first pending trigger is kept; the coalesced speech rides along
    /// regardless, so a later trigger needn't displace it.
    private enum TriggerClaim {
        case claimed
        case pending
        case terminalFailure
    }

    private func claimOrPend(_ reason: TriggerReason) -> TriggerClaim {
        stateLock.lock(); defer { stateLock.unlock() }
        if terminalBrainFailure { return .terminalFailure }
        if isHandling {
            if pendingTrigger == nil { pendingTrigger = reason }
            return .pending
        }
        isHandling = true
        return .claimed
    }

    /// Latch/report only if the failing turn still belongs to the active provider. A user can switch
    /// providers while an old request is in flight; that stale failure must not stop the replacement.
    private func latchTerminalBrainFailure(for revision: UInt) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard brainConfiguration.revision == revision else { return false }
        terminalBrainFailure = true
        pendingTrigger = nil
        return true
    }

    /// Recheck at main-actor delivery, not only when the request unwinds. A Settings update can run
    /// after a terminal failure is latched but before its callback reaches the app; that stale
    /// callback must not stop the replacement provider.
    private func isCurrentBrainConfiguration(_ revision: UInt) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return brainConfiguration.revision == revision
    }

    /// Atomically take the next pending trigger (keeping the slot) OR release the slot. One critical
    /// section so a trigger arriving exactly as a turn finishes is never orphaned.
    private func finishTurnOrTakeNext() -> TriggerReason? {
        stateLock.lock(); defer { stateLock.unlock() }
        if let next = pendingTrigger { pendingTrigger = nil; return next }   // keep isHandling = true
        isHandling = false
        return nil
    }

    @discardableResult
    public func handleTrigger(_ reason: TriggerReason) async -> TurnOutcome {
        // Single-in-flight, but we COALESCE rather than drop: a trigger arriving while a turn runs is
        // recorded as pending and picked up by the running turn when it finishes — so nothing is lost
        // and turns can't pile up. The batched speech rides along automatically via the sent-index.
        switch claimOrPend(reason) {
        case .claimed:
            break
        case .pending:
            jlog("… busy; batching this \(reason) into the running turn")
            return .busy
        case .terminalFailure:
            jlog("… terminal brain failure already ended this coaching session")
            return .brainError
        }
        var current = reason
        var outcome: TurnOutcome = .silentByModel
        while true {
            outcome = await runTurn(current)
            guard let next = finishTurnOrTakeNext() else { return outcome }
            current = next
        }
    }

    /// Run one coaching turn for `reason`.
    private func runTurn(_ reason: TriggerReason) async -> TurnOutcome {
        // Stop may have cancelled this turn before it got the slot.
        if Task.isCancelled { jlog("… turn cancelled (stopped) before handling"); return .cancelled }

        // Turn-end already shows up as the "🗣 heard:" line from the transcriber; only the silence
        // trigger needs its own marker.
        if case .silence(let secs) = reason { jlog("🤫 quiet for \(Int(secs))s") }

        let now = clock.now()
        let ctx = TriggerContext(reason: reason, sessionElapsedSeconds: now - sessionStart)

        // A hotkey trigger leaves no "🗣 heard:" line (the user pressed a key, didn't speak), so record
        // it — with the synthetic request we pre-fill as the user's message — so the activity viewer
        // shows what the shortcut sent to the brain.
        if reason == .manualHint, let line = ctx.promptLine {
            jlog("⌨️ hint shortcut — \(line)")
            ActivityLog.shared.record(.manualHint(prompt: line))
        }

        // The delta: only the lines the brain hasn't seen yet (the rest live in `history`).
        let delta = transcript.renderFrom(index: currentSentCount())

        // The substance gate: a turn-end whose delta is pure back-channel filler (from EITHER
        // speaker) or empty never becomes a request — filler can't produce a tip, and the request
        // would re-bill the whole working set just to decide "stay silent". The unsent lines ride
        // along on the next substantive turn (sentCount only advances on a send); silence and
        // manual-hint triggers always go through. Logged so gate misfires are auditable.
        if reason == .turnEnd && !delta.lines.contains(where: TurnSubstance.isSubstantive) {
            // Log WHAT was skipped (not just that a skip happened) so a gate misfire — a real remark
            // wrongly classified as filler — is visible in the debug log, not silent.
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
        // an empty turn-end delta is gated above, and silence/manual-hint always have a note.
        let userText = [delta.text.isEmpty ? nil : "New since last turn:\n\(delta.text)",
                        ctx.promptLine].compactMap { $0 }.joined(separator: "\n\n")
        var turnMessages: [ChatMessage] = [.user(userText)]

        // Keep one provider/model for the whole turn, including the manual-hint capture below. This
        // snapshot must precede that await: a Settings update while capture is in flight belongs to
        // the next turn, not the already-started hint.
        var brains = currentBrainConfiguration()

        // Manual hint (hotkey): the user explicitly asked for help, so capture the screen HERE and
        // inject it into THIS first request — no waiting for the model to call capture_screen.
        // Forcing `speak` (below) then guarantees a visible hint in a single round trip. Same
        // off-pool capture + post-capture cancellation guard as the capture_screen tool branch.
        if reason == .manualHint {
            let screen = self.screen
            let shot = await Task.detached(priority: .userInitiated, operation: { screen.capture() }).value
            if Task.isCancelled { jlog("… turn cancelled (stopped) after capture"); return .cancelled }
            if let shot {
                jlog("👁 looking at your screen")
                ActivityLog.shared.record(.screenViewed(imageBase64JPEG: shot.imageBase64))
                turnMessages.append(.userImage(shot.imageBase64))
                // OCR sidecar: the same window as exact text, so the model reads code instead of
                // deciphering pixels. Rides as its own user message — there's no tool result to
                // carry it on this pre-injected path.
                if let text = shot.recognizedText {
                    jlog("🔤 read \(text.count(where: { $0 == "\n" }) + 1) lines of on-screen text")
                    turnMessages.append(.user(Self.recognizedTextBlock(text)))
                }
            } else {
                jlog("👁 screenshot failed")
                ActivityLog.shared.record(.screenViewFailed)
            }   // still force a hint from transcript/history
        }

        // Force `speak` ONLY for an explicit manual hint; audio-driven turns use `.required` — SOME
        // tool, the model's pick (speak, look at the screen, or stay_silent). Requiring a call is what
        // keeps a stay-quiet decision from leaking free deliberation text into the stored history.
        let turnToolChoice: ToolChoice = (reason == .manualHint) ? .force(speakTool.name) : .required

        jlog("💭 thinking…")

        // Settings updates atomically replace the shared configuration, but this turn continues on
        // its snapshot and the next turn sees it. If an unconfirmed replacement fails, discard its
        // provider-specific tool state and restart this same turn from the original provider-neutral
        // messages on the last working brain.
        let initialTurnMessages = turnMessages
        var committed = false
        var iterations = 0
        var lastResponseCompleted = false
        while iterations < maxToolIterations {
            iterations += 1
            let response: BrainResponse
            do {
                response = try await brains.brain.respond(messages: historyBase + turnMessages,
                                                          tools: coachTools, toolChoice: turnToolChoice)
            } catch {
                // A cancellation (barge-in / Stop) is expected — report it quietly, not as a failure.
                if Task.isCancelled { jlog("… turn cancelled (interrupted)"); return .cancelled }
                let detail = error.localizedDescription
                jlog("Jarvis coach: brain request failed on \(reason): \(detail)")
                if let fallback = restoreFallback(for: brains) {
                    jlog("Jarvis coach: replacement brain failed — retrying this turn on the previous configuration")
                    fallback.callback?(brains.provider, fallback.configuration.provider)
                    brains = fallback.configuration
                    turnMessages = initialTurnMessages
                    iterations = 0
                    lastResponseCompleted = false
                    continue
                }
                if let onFailure = brains.onFailure {
                    let failure = BrainFailure(error)
                    if failure.disposition == .temporary {
                        await MainActor.run {
                            guard isCurrentBrainConfiguration(brains.revision) else {
                                jlog("… ignoring queued failure from superseded brain configuration")
                                return
                            }
                            onFailure(failure)
                        }
                    } else if latchTerminalBrainFailure(for: brains.revision) {
                        await MainActor.run {
                            guard isCurrentBrainConfiguration(brains.revision) else {
                                jlog("… ignoring queued failure from superseded brain configuration")
                                return
                            }
                            onFailure(failure)
                        }
                    } else {
                        jlog("… ignoring failure from superseded brain configuration")
                    }
                }
                // Speech already marked sent (a later-iteration failure) must not vanish from memory —
                // commit what this turn accumulated. A first-request failure commits nothing; the
                // un-advanced sentCount re-sends the delta next turn instead.
                if committed { commitIfWorthKeeping(turnMessages, deltaText: delta.text) }
                return .brainError
            }
            lastResponseCompleted = response.incompleteReason == nil
            // The input provably reached the server — NOW mark the delta as sent.
            if !committed { advanceSentCount(to: delta.upTo); committed = true }

            if Task.isCancelled {
                jlog("… turn cancelled (stopped) mid-think")
                commitIfWorthKeeping(turnMessages, deltaText: delta.text)   // the delta was sent; keep memory consistent with it
                return .cancelled
            }

            // No tool call → a TRUNCATED run (zero items because reasoning blew the token cap), or a
            // model ignoring `tool_choice: required`. Treat the latter as silence — rendering nothing
            // is the safe interpretation. Either way the sent delta must land in memory.
            guard let call = response.toolCalls.first else {
                commitIfWorthKeeping(turnMessages, deltaText: delta.text)
                if let reasonText = response.incompleteReason {
                    jlog("⚠️ response truncated (\(reasonText)) — not deliberate silence")
                    // An incomplete response does not prove the replacement can finish a turn. Keep
                    // the previous provider available for a later request failure.
                    return .truncated
                }
                jlog("… nothing useful to add, staying silent")
                confirmBrainConfiguration(brains.revision)
                await compactIfNeeded(using: brains)
                return .silentByModel
            }

            if let reasonText = response.incompleteReason {
                jlog("⚠️ response incomplete (\(reasonText)) — not confirming a brain change")
            }

            switch call {
            case .captureScreen(let callId):
                // ScreenCaptureCLI shells out to `screencapture` and blocks for 100s of ms; run it
                // off the cooperative pool so it doesn't stall a pool thread while holding the slot.
                let screen = self.screen
                let shot = await Task.detached(priority: .userInitiated, operation: { screen.capture() }).value
                // Stop may have fired during the (un-cancellable, detached) capture. Bail before
                // emitting: otherwise this screenshot — and the reasoning that follows — would be
                // logged into whatever session is now current (a Start rotates the log mid-turn).
                if Task.isCancelled {
                    jlog("… turn cancelled (stopped) after capture")
                    history.commit(turnMessages)
                    return .cancelled
                }
                if let shot {
                    jlog("👁 looking at your screen")
                    ActivityLog.shared.record(.screenViewed(imageBase64JPEG: shot.imageBase64))
                    if let text = shot.recognizedText {
                        jlog("🔤 read \(text.count(where: { $0 == "\n" }) + 1) lines of on-screen text")
                    }
                } else {
                    jlog("👁 screenshot failed")
                    ActivityLog.shared.record(.screenViewFailed)
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
                ActivityLog.shared.record(.tip(lines: lines))
                let perLine = lines.map { OverlayTiming.displaySeconds(for: $0, config: config) }
                overlay.render(lines, perLineSeconds: perLine)
                // Close the call locally — we own the history, so no follow-up round trip is needed.
                turnMessages.append(.assistantToolCalls(response.rawToolCalls))
                turnMessages.append(.init(role: .tool, text: "shown to the user", toolCallId: callId))
                history.commit(turnMessages)
                if lastResponseCompleted {
                    confirmBrainConfiguration(brains.revision)
                }
                await compactIfNeeded(using: brains)
                return .spoke

            case .staySilent:
                // The model's explicit stay-quiet decision belongs in the human-facing Activity
                // record like every other brain action. It still stays out of model memory: replaying
                // the call and its non-answer would only bloat every later request.
                jlog("… nothing useful to add, staying silent")
                ActivityLog.shared.record(.stayedSilent)
                commitIfWorthKeeping(turnMessages, deltaText: delta.text)
                if lastResponseCompleted {
                    confirmBrainConfiguration(brains.revision)
                }
                await compactIfNeeded(using: brains)
                return .silentByModel
            }
        }
        jlog("… tool loop exhausted without speaking")
        history.commit(turnMessages)   // captures + speech stay in memory even on the backstop path
        if lastResponseCompleted {
            confirmBrainConfiguration(brains.revision)
        }
        await compactIfNeeded(using: brains)
        return .exhausted
    }

    /// Commit a finished turn to session memory ONLY when it left something a later turn can use —
    /// new transcript lines, or tool activity (a capture the model may refer back to). A turn that
    /// was just a trigger note the model shrugged at (a silence check → stay_silent) is dropped
    /// whole: committing it would pile up answerless user messages in memory, re-billed on every
    /// later request and confusing to read back.
    private func commitIfWorthKeeping(_ turn: [ChatMessage], deltaText: String) {
        guard !deltaText.isEmpty || turn.count > 1 else { return }
        history.commit(turn)
    }

    /// The capture_screen tool-result text: the OCR sidecar rides here when present, so exact text
    /// and the image arrive as one result the model reasons over together.
    private static func captureResultText(_ shot: ScreenSnapshot) -> String {
        guard let text = shot.recognizedText else { return "screenshot captured" }
        return "screenshot captured\n\n\(recognizedTextBlock(text))"
    }

    /// Framed so the model treats OCR as a reading aid, not gospel — recognition mangles the odd
    /// identifier, and the screenshot stays the ground truth to verify against. Opens with
    /// `CoachHistory.ocrHeader` so commit-time collapse of superseded OCR can't drift out of sync.
    private static func recognizedTextBlock(_ text: String) -> String {
        "\(CoachHistory.ocrHeader)\n\(text)"
    }

    // MARK: - History compaction

    /// When the session memory outgrows the threshold, condense its oldest span into a short summary
    /// (via `summarizer`, falling back to the coach brain). Runs while still holding the turn slot —
    /// a concurrent trigger just coalesces, so there's no compaction/turn race — and fails soft: on
    /// any error the full history simply rides along until the next attempt.
    private func compactIfNeeded(using brains: BrainConfiguration) async {
        guard history.estimatedTokens > config.historyCompactionTokenThreshold else { return }
        guard let (oldest, count) = history.compactionPrefix() else { return }
        do {
            let response = try await (brains.summarizer ?? brains.brain).respond(
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
    case exhausted        // ran the tool loop to the cap without a terminal speak
}
