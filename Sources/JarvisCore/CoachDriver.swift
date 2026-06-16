import Foundation

/// The event loop. On a trigger, calls the brain with the timestamped transcript + timing context
/// and the tool set, and routes tool calls (capture_screen, speak). All judgment lives in the
/// model — including when to stay quiet and when to answer a direct address — so this just wires
/// events to tool calls. There is no cooldown or rate cap: every utterance reaches the brain and
/// the brain decides whether it has anything worth saying (the system prompt carries that restraint).
///
/// `@unchecked Sendable` is justified: the only mutable state is guarded by a lock, and the injected
/// dependencies are each either immutable or internally synchronized. A single in-flight turn is
/// enforced by `claimOrPend()` — an atomic check-then-set taken before any `await` — so two
/// concurrent triggers can't run overlapping turns; the second is coalesced into the first.
public final class CoachDriver: @unchecked Sendable {
    private let config: Config
    private let transcript: RollingTranscript
    private let brain: BrainClient
    private let screen: ScreenCapturing
    private let overlay: OverlayRendering
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let onSpoke: (@Sendable () -> Void)?

    /// Safety backstop against a pathological model that loops on capture_screen forever.
    private let maxToolIterations = 4

    /// Conversation-create backoff: retry this often after a failed POST /v1/conversations, so a
    /// transient blip doesn't latch the whole session into stateless mode.
    private let conversationRetrySeconds: TimeInterval = 60

    private let stateLock = NSLock()
    private var isHandling = false
    /// One server-side conversation per coaching session (this driver is rebuilt on each Start), so
    /// the model keeps continuity — its own prior replies included — across triggers.
    private var conversationId: String?
    /// While set (and `now` is before it), skip creating a conversation — a recent create failed.
    private var createBackoffUntil: TimeInterval?
    /// Number of transcript lines already sent to the conversation. Each turn sends `lines[sentCount...]`
    /// and advances this ONLY after the input reached the server, so a failed turn re-sends its speech.
    private var sentCount = 0
    /// A tool call (a terminal `speak`, or a capture left unanswered at the iteration cap) awaiting its
    /// tool-result. We close it on the NEXT turn — but the callId is retained until the close provably
    /// reaches the server, so a failed/cancelled next turn can't strand it and dangle the conversation.
    private var pendingCloseCallId: String?
    /// A trigger that arrived while a turn was running — coalesced into the running turn's follow-up so
    /// nothing is dropped and turns don't pile up (a direct address wins over an ambient trigger).
    private var pendingTrigger: TriggerReason?

    public init(config: Config, transcript: RollingTranscript,
                brain: BrainClient, screen: ScreenCapturing, overlay: OverlayRendering, clock: Clock,
                onSpoke: (@Sendable () -> Void)? = nil) {
        self.config = config
        self.transcript = transcript
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
    private func currentPendingCloseCallId() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }; return pendingCloseCallId
    }
    private func setPendingCloseCallId(_ id: String) {
        stateLock.lock(); pendingCloseCallId = id; stateLock.unlock()
    }
    private func clearPendingCloseCallId() {
        stateLock.lock(); pendingCloseCallId = nil; stateLock.unlock()
    }

    /// Atomically claim the single in-flight slot, OR (if busy) record the trigger as pending. One
    /// critical section so a trigger can never slip between "am I busy?" and "set pending" and be lost.
    /// Returns true if this call now owns the turn loop. The first pending trigger is kept; the
    /// coalesced speech rides along regardless, so a later trigger needn't displace it.
    private func claimOrPend(_ reason: TriggerReason) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if isHandling {
            if pendingTrigger == nil { pendingTrigger = reason }
            return false
        }
        isHandling = true
        return true
    }

    /// Atomically take the next pending trigger (keeping the slot) OR release the slot. One critical
    /// section so a trigger arriving exactly as a turn finishes is never orphaned.
    private func finishTurnOrTakeNext() -> TriggerReason? {
        stateLock.lock(); defer { stateLock.unlock() }
        if let next = pendingTrigger { pendingTrigger = nil; return next }   // keep isHandling = true
        isHandling = false
        return nil
    }

    /// Lazily create the session's conversation. Returns nil (run statelessly) if creation fails, but
    /// retries after `conversationRetrySeconds` so a transient blip doesn't latch the whole session.
    private func ensureConversation() async -> String? {
        if let existing = currentConversationId() { return existing }
        if inCreateBackoff() { return nil }
        do {
            let id = try await brain.createConversation()
            storeConversationId(id)
            return id
        } catch {
            beginCreateBackoff()
            jlog("Jarvis coach: conversation create failed — continuing stateless for now: \(error.localizedDescription)")
            return nil
        }
    }
    private func storeConversationId(_ id: String?) {
        stateLock.lock(); conversationId = id; stateLock.unlock()
    }
    private func inCreateBackoff() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if let until = createBackoffUntil { return clock.now() < until }
        return false
    }
    private func beginCreateBackoff() {
        stateLock.lock(); createBackoffUntil = clock.now() + conversationRetrySeconds; stateLock.unlock()
    }

    @discardableResult
    public func handleTrigger(_ reason: TriggerReason) async -> TurnOutcome {
        // Single-in-flight, but we COALESCE rather than drop: a trigger arriving while a turn runs is
        // recorded as pending and picked up by the running turn when it finishes — so nothing is lost
        // and turns can't pile up. The batched speech rides along automatically via the sent-index.
        guard claimOrPend(reason) else {
            jlog("… busy; batching this \(reason) into the running turn")
            return .busy
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
        let ctx = TriggerContext(
            reason: reason,
            secondsSinceLastSpeech: transcript.silenceDuration(now: now),
            sessionElapsedSeconds: now - sessionStart
        )

        // Context: when conversation-backed, send only the NEW lines (the server holds the rest),
        // tracked by index. When STATELESS (no conversation), send a full recent window every turn —
        // there's no server history, so a delta would starve the model of the problem statement.
        let convId = await ensureConversation()
        let upTo: Int
        let newSpeech: String
        if convId != nil {
            let delta = transcript.renderFrom(index: currentSentCount())   // single snapshot: text + upTo
            newSpeech = delta.text; upTo = delta.upTo
        } else {
            newSpeech = transcript.renderWindow(seconds: config.transcriptWindowSeconds, now: now)
            upTo = 0   // unused: stateless mode never advances the sent-index
        }

        // Close any prior unanswered tool call (a `speak`, or a capture left at the iteration cap),
        // bundled here so the conversation never dangles. PEEK only — we don't drop it until the close
        // provably reaches the server (below), so a failed/cancelled turn re-sends it.
        var convo: [ChatMessage] = [.system(coachSystemPrompt)]
        let priorClose = convId != nil ? currentPendingCloseCallId() : nil
        if let priorClose {
            convo.append(.init(role: .tool, text: "shown to the user", toolCallId: priorClose))
        }
        convo.append(.user("""
            New since last turn (timestamped):
            \(newSpeech.isEmpty ? "(nothing new)" : newSpeech)

            \(ctx.promptLine)
            """))

        jlog("💭 thinking…")

        var committed = false
        var unansweredCaptureCallId: String?   // a capture whose result hasn't been sent yet this turn
        var iterations = 0
        while iterations < maxToolIterations {
            iterations += 1
            let response: BrainResponse
            do {
                // No forcing: the model picks the tool from the prompt (reply, look at the screen, or
                // stay quiet). The system prompt tells it to answer when addressed and stay silent
                // otherwise — that judgment lives in the model, not in a guardrail here.
                response = try await brain.respond(messages: convo, tools: coachTools,
                                                   toolChoice: .auto, conversationId: convId)
            } catch {
                // A cancellation (barge-in / Stop) is expected — report it quietly, not as a failure.
                if Task.isCancelled { jlog("… turn cancelled (interrupted)"); return .cancelled }
                jlog("Jarvis coach: brain request failed on \(reason): \(error.localizedDescription)")
                return .brainError
            }
            // The input provably reached the server — NOW commit the conversation-state mutations:
            // advance the sent-index, and drop the prior close we just delivered. (Only when
            // conversation-backed; stateless mode keeps re-sending the window and never advances.)
            if !committed {
                if convId != nil { advanceSentCount(to: upTo); if priorClose != nil { clearPendingCloseCallId() } }
                committed = true
            }
            // Whatever capture result was in this request's body has now been sent.
            unansweredCaptureCallId = nil

            if Task.isCancelled { jlog("… turn cancelled (stopped) mid-think"); return .cancelled }

            // No tool call → deliberate silence or a TRUNCATED run (zero items because reasoning blew
            // the token cap — a bug signal, not a coaching decision).
            guard let call = response.toolCalls.first else {
                if let reasonText = response.incompleteReason {
                    jlog("⚠️ response truncated (\(reasonText)) — not deliberate silence")
                    return .truncated
                }
                jlog("… nothing useful to add, staying silent")
                return .silentByModel
            }

            switch call {
            case .captureScreen(let callId):
                // ScreenCaptureCLI shells out to `screencapture` and blocks for 100s of ms; run it
                // off the cooperative pool so it doesn't stall a pool thread while holding the slot.
                let screen = self.screen
                let img = await Task.detached(priority: .userInitiated, operation: { screen.capture() }).value
                if let img { jlog("👁 looking at your screen", image: img) }   // thumbnail in the dev viewer
                else { jlog("👁 screenshot failed") }
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
                // The result is queued in `convo` to be sent on the NEXT iteration; if the loop hits
                // the cap first, this capture is left unanswered and must be closed on the next turn.
                if convId != nil { unansweredCaptureCallId = callId }
                continue // let the model reason over the image

            case .speak(let callId, let text):
                jlog("💬 \(text)")
                overlay.render(text, maxSentences: config.maxSentences,
                               perSentenceSeconds: config.sentenceDisplaySeconds)
                onSpoke?()
                // `speak` is terminal; its tool-result is sent on the next turn so the conversation
                // stays valid without an extra round-trip now.
                if convId != nil { setPendingCloseCallId(callId) }
                return .spoke
            }
        }
        jlog("… tool loop exhausted without speaking")
        // Don't leave a final-iteration capture dangling — close it on the next turn.
        if convId != nil, let cap = unansweredCaptureCallId { setPendingCloseCallId(cap) }
        return .exhausted
    }
}

/// The terminal outcome of a coaching turn — surfaced so every "quiet" path is observable instead
/// of a silent `return`. Tuning VAD / silence-backoff thresholds depends on knowing WHICH of these
/// fired.
public enum TurnOutcome: Sendable, Equatable {
    case spoke            // rendered a coaching tip
    case silentByModel    // model deliberately called no tool
    case truncated        // response cut off by the token cap (NOT a real silence decision)
    case busy             // a turn was in flight; this trigger was coalesced into it (not dropped)
    case cancelled        // Stop cancelled the turn
    case brainError       // the brain request threw (401/429/network)
    case exhausted        // ran the tool loop to the cap without a terminal speak
}
