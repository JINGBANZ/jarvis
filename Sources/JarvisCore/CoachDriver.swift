import Foundation

/// The event loop. On a trigger, enforces guardrails, calls the brain with the timestamped
/// transcript + timing context and the tool set, and routes tool calls (capture_screen, speak).
/// All judgment lives in the model; this just wires events to tool calls and enforces safety.
///
/// `@unchecked Sendable` is justified: the only mutable state (`isHandling`) is guarded by a lock,
/// and the injected dependencies are each either immutable or internally synchronized. A single
/// in-flight turn is enforced by `beginHandling()` — an atomic check-then-set taken before any
/// `await` — which closes the check-then-act window between `guardrails.allow()` and `noteSpoke()`
/// that would otherwise let two concurrent triggers double-interject.
public final class CoachDriver: @unchecked Sendable {
    private let config: Config
    private let transcript: RollingTranscript
    private let guardrails: Guardrails
    private let brain: BrainClient
    private let screen: ScreenCapturing
    private let overlay: OverlayRendering
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let onSpoke: (@Sendable () -> Void)?

    /// Safety backstop against a pathological model that loops on capture_screen forever.
    private let maxToolIterations = 4

    private let stateLock = NSLock()
    private var isHandling = false
    /// One server-side conversation per coaching session (this driver is rebuilt on each Start), so
    /// the model keeps continuity — its own prior replies included — across triggers.
    private var conversationId: String?
    /// Set once if conversation creation fails, so we don't re-POST /v1/conversations every turn.
    private var conversationCreationFailed = false
    /// Number of transcript lines already sent to the conversation. Each turn sends `lines[sentCount...]`
    /// and advances this ONLY after the input reached the server, so a failed turn re-sends its speech.
    private var sentCount = 0
    /// A `speak` call awaiting its tool-result. We close it on the NEXT turn (bundled with new speech)
    /// so the server-side conversation never dangles, without paying an extra round-trip per reply.
    private var pendingSpeakCallId: String?
    /// A trigger that arrived while a turn was running — coalesced into the running turn's follow-up so
    /// nothing is dropped and turns don't pile up (a direct address wins over an ambient trigger).
    private var pendingTrigger: TriggerReason?

    public init(config: Config, transcript: RollingTranscript, guardrails: Guardrails,
                brain: BrainClient, screen: ScreenCapturing, overlay: OverlayRendering, clock: Clock,
                onSpoke: (@Sendable () -> Void)? = nil) {
        self.config = config
        self.transcript = transcript
        self.guardrails = guardrails
        self.brain = brain
        self.screen = screen
        self.overlay = overlay
        self.clock = clock
        self.sessionStart = clock.now()
        self.onSpoke = onSpoke
    }

    // Synchronous lock accessors — NSLock can't be held across an `await`, so all critical sections
    // live in non-async helpers.
    private func currentConversationId() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }; return conversationId
    }
    private func currentSentCount() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }; return sentCount
    }
    /// Advance the read position (forward only) once the input has reached the conversation.
    private func advanceSentCount(to upTo: Int) {
        stateLock.lock(); if upTo > sentCount { sentCount = upTo }; stateLock.unlock()
    }
    private func takePendingSpeakCallId() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        let id = pendingSpeakCallId; pendingSpeakCallId = nil; return id
    }
    private func setPendingSpeakCallId(_ id: String) {
        stateLock.lock(); pendingSpeakCallId = id; stateLock.unlock()
    }
    /// Record a trigger that arrived while busy. A direct address takes priority over an ambient one.
    private func setPendingTrigger(_ reason: TriggerReason) {
        stateLock.lock(); defer { stateLock.unlock() }
        if pendingTrigger == nil || reason.isDirectAddress { pendingTrigger = reason }
    }
    private func takePendingTrigger() -> TriggerReason? {
        stateLock.lock(); defer { stateLock.unlock() }
        let r = pendingTrigger; pendingTrigger = nil; return r
    }

    /// Lazily create the session's conversation (once). Returns nil if creation fails (after which we
    /// stop retrying and run statelessly) rather than blocking coaching.
    private func ensureConversation() async -> String? {
        if let existing = currentConversationId() { return existing }
        if creationFailedFlag() { return nil }
        do {
            let id = try await brain.createConversation()
            storeConversationId(id)
            return id
        } catch {
            markCreationFailed()
            jlog("Jarvis coach: conversation create failed — continuing stateless: \(error.localizedDescription)")
            return nil
        }
    }
    private func storeConversationId(_ id: String?) {
        stateLock.lock(); conversationId = id; stateLock.unlock()
    }
    private func creationFailedFlag() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return conversationCreationFailed
    }
    private func markCreationFailed() {
        stateLock.lock(); conversationCreationFailed = true; stateLock.unlock()
    }

    /// Atomically claim the single in-flight slot; false if a turn is already running.
    private func beginHandling() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if isHandling { return false }
        isHandling = true
        return true
    }

    private func endHandling() {
        stateLock.lock(); isHandling = false; stateLock.unlock()
    }

    @discardableResult
    public func handleTrigger(_ reason: TriggerReason) async -> TurnOutcome {
        // Single-in-flight, but we COALESCE rather than drop: a trigger arriving while a turn runs is
        // recorded as pending and picked up by the running turn when it finishes — so nothing is lost
        // and turns can't pile up. The batched speech rides along automatically via the sent-index.
        guard beginHandling() else {
            setPendingTrigger(reason)
            jlog("… busy; batching this \(reason) into the running turn")
            return .busy
        }
        defer { endHandling() }

        var current = reason
        var outcome: TurnOutcome = .silentByModel
        while true {
            outcome = await runTurn(current)
            guard let next = takePendingTrigger() else { return outcome }
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

        // Direct address bypasses the ambient cooldown/rate-cap (honoring only mute + its own looser
        // ceiling); all other triggers go through the full guardrail gate.
        if reason.isDirectAddress {
            guard guardrails.allowDirect() else {
                jlog("… held back (muted or direct-address rate cap)")
                return .heldBack
            }
        } else {
            guard guardrails.allow() else {
                jlog("… held back (cooldown or rate cap)")
                return .heldBack
            }
        }

        let now = clock.now()
        let ctx = TriggerContext(
            reason: reason,
            secondsSinceLastSpeech: transcript.silenceDuration(now: now),
            sessionElapsedSeconds: now - sessionStart
        )

        // Send only the NEW transcript lines (the conversation holds the rest), tracked by index.
        let convId = await ensureConversation()
        let upTo = transcript.count
        let newSpeech = transcript.renderFrom(index: currentSentCount())

        // Close any prior `speak` call (lazily, bundled here) so the conversation never dangles.
        var convo: [ChatMessage] = [.system(coachSystemPrompt)]
        if convId != nil, let priorSpeak = takePendingSpeakCallId() {
            convo.append(.init(role: .tool, text: "shown to the user", toolCallId: priorSpeak))
        }
        convo.append(.user("""
            New since last turn (timestamped):
            \(newSpeech.isEmpty ? "(nothing new)" : newSpeech)

            \(ctx.promptLine)
            """))

        jlog("💭 thinking…")

        var advanced = false
        var iterations = 0
        while iterations < maxToolIterations {
            iterations += 1
            let response: BrainResponse
            do {
                // No forcing: the model picks the tool from the prompt (reply, look at the screen, or
                // stay quiet). The wake-word already guarantees a direct address gets THROUGH the
                // cooldown, and directAddressFallback() guarantees it's never met with total silence.
                response = try await brain.respond(messages: convo, tools: coachTools,
                                                   toolChoice: .auto, conversationId: convId)
            } catch {
                // A cancellation (barge-in / Stop) is expected — report it quietly, not as a failure.
                if Task.isCancelled { jlog("… turn cancelled (interrupted)"); return .cancelled }
                jlog("Jarvis coach: brain request failed on \(reason): \(error.localizedDescription)")
                return .brainError
            }
            // The input reached the conversation — advance the sent-index so we don't re-send it.
            if !advanced { advanceSentCount(to: upTo); advanced = true }

            if Task.isCancelled { jlog("… turn cancelled (stopped) mid-think"); return .cancelled }

            // No tool call → deliberate silence or a TRUNCATED run (zero items because reasoning blew
            // the token cap — a bug signal, not a coaching decision).
            guard let call = response.toolCalls.first else {
                if let reasonText = response.incompleteReason {
                    jlog("⚠️ response truncated (\(reasonText)) — not deliberate silence")
                    if reason.isDirectAddress { return directAddressFallback() }
                    return .truncated
                }
                if reason.isDirectAddress { return directAddressFallback() }
                jlog("… nothing useful to add, staying silent")
                return .silentByModel
            }

            switch call {
            case .captureScreen(let callId):
                jlog("👁 looking at your screen")
                // ScreenCaptureCLI shells out to `screencapture` and blocks for 100s of ms; run it
                // off the cooperative pool so it doesn't stall a pool thread while holding the slot.
                let screen = self.screen
                let img = await Task.detached(priority: .userInitiated, operation: { screen.capture() }).value
                if convId == nil {
                    // Stateless fallback: replay the model's call + the tool result + image.
                    convo.append(.assistantToolCalls(response.rawToolCalls))
                    if let img {
                        convo.append(.init(role: .tool, text: "screenshot captured", toolCallId: callId))
                        convo.append(.userImage(img))
                    } else {
                        convo.append(.init(role: .tool, text: "screenshot failed", toolCallId: callId))
                    }
                } else {
                    // The conversation holds the function_call; send only the tool result (+ image).
                    var next: [ChatMessage] = [.system(coachSystemPrompt)]
                    if let img {
                        next.append(.init(role: .tool, text: "screenshot captured", toolCallId: callId))
                        next.append(.userImage(img))
                    } else {
                        next.append(.init(role: .tool, text: "screenshot failed", toolCallId: callId))
                    }
                    convo = next
                }
                continue // let the model reason over the image

            case .speak(let callId, let text):
                jlog("💬 \(text)")
                overlay.render(text, maxSentences: config.maxSentences,
                               perSentenceSeconds: config.sentenceDisplaySeconds)
                // Direct replies count toward the direct ceiling but don't start the ambient cooldown
                // (a reply shouldn't mute the next coaching nudge); ambient tips do.
                if reason.isDirectAddress { guardrails.noteDirectAddress() } else { guardrails.noteSpoke() }
                onSpoke?()
                // `speak` is terminal; its tool-result is sent on the next turn so the conversation
                // stays valid without an extra round-trip now.
                if convId != nil { setPendingSpeakCallId(callId) }
                return .spoke
            }
        }
        jlog("… tool loop exhausted without speaking")
        if reason.isDirectAddress { return directAddressFallback() }
        return .exhausted
    }

    /// Last-resort spoken reply so a direct address is never met with silence (e.g. the model
    /// truncated or looped without speaking). Counts toward the direct ceiling, not the cooldown.
    private func directAddressFallback() -> TurnOutcome {
        let text = "Sorry — I didn't catch that. Could you say it again?"
        jlog("💬 \(text)")
        overlay.render(text, maxSentences: config.maxSentences,
                       perSentenceSeconds: config.sentenceDisplaySeconds)
        guardrails.noteDirectAddress()
        onSpoke?()
        return .spokeFallback
    }
}

/// The terminal outcome of a coaching turn — surfaced so every "quiet" path is observable instead
/// of a silent `return`. Tuning cooldown / VAD / silence thresholds depends on knowing WHICH of
/// these fired.
public enum TurnOutcome: Sendable, Equatable {
    case spoke            // rendered a coaching tip
    case spokeFallback    // direct address that the model didn't answer → canned spoken reply
    case silentByModel    // model deliberately called no tool
    case truncated        // response cut off by the token cap (NOT a real silence decision)
    case heldBack         // guardrail blocked: cooldown, rate cap, or mute
    case busy             // a turn was already in flight; this trigger was dropped
    case cancelled        // Stop cancelled the turn
    case brainError       // the brain request threw (401/429/network)
    case exhausted        // ran the tool loop to the cap without a terminal speak
}
