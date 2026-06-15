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
    /// Transcript time already sent to the model; each turn sends only newer speech (the conversation
    /// holds the rest). Starts at the session origin so the first turn sends what's been said so far.
    private var lastReadTime: TimeInterval

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
        self.lastReadTime = clock.now()
        self.onSpoke = onSpoke
    }

    // Synchronous lock accessors — NSLock can't be held across an `await`, so all critical sections
    // live in non-async helpers.
    private func currentConversationId() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }; return conversationId
    }
    private func storeConversationId(_ id: String?) {
        stateLock.lock(); conversationId = id; stateLock.unlock()
    }
    /// Return the prior read time and advance it to `now` (so the next turn sends only newer speech).
    private func advanceReadTime(to now: TimeInterval) -> TimeInterval {
        stateLock.lock(); defer { stateLock.unlock() }
        let since = lastReadTime; lastReadTime = now; return since
    }

    /// Lazily create the session's conversation (once). Returns nil if creation fails, in which case
    /// the turn proceeds statelessly rather than blocking coaching.
    private func ensureConversation() async -> String? {
        if let existing = currentConversationId() { return existing }
        let id = try? await brain.createConversation()
        storeConversationId(id)
        return id
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
        // Single-in-flight: a second trigger arriving while a (possibly slow) turn is running is
        // dropped — but NO LONGER silently. This drop is a common reason Jarvis "ignores" a
        // back-to-back utterance, so it is logged and reported.
        guard beginHandling() else {
            jlog("… busy with the previous turn, skipped this \(reason)")
            return .busy
        }
        defer { endHandling() }

        // Stop may have cancelled this turn before it got the slot.
        if Task.isCancelled { jlog("… turn cancelled (stopped) before handling"); return .cancelled }

        // Turn-end already shows up as the "🗣 heard:" line from the transcriber; only the silence
        // trigger needs its own marker.
        if case .silence(let secs) = reason { jlog("🤫 quiet for \(Int(secs))s") }

        // Direct address must reach the user even mid-cooldown: it bypasses the ambient
        // cooldown/rate-cap, honoring only mute and its own looser ceiling. All other triggers go
        // through the full guardrail gate.
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

        // Server-side conversation holds the running history (the user's earlier speech AND Jarvis's
        // own prior replies), so we send only the NEW speech since the last turn.
        let convId = await ensureConversation()
        let since = advanceReadTime(to: now)
        let newSpeech = transcript.renderSince(after: since, now: now)

        var convo: [ChatMessage] = [
            .system(coachSystemPrompt),
            .user("""
            New since last turn (timestamped):
            \(newSpeech.isEmpty ? "(nothing new)" : newSpeech)

            \(ctx.promptLine)
            """),
        ]

        jlog("💭 thinking…")

        // Direct address must produce a reply: force the speak tool. Other triggers keep "auto" so
        // silence-by-default still works.
        let toolChoice: ToolChoice = reason.isDirectAddress ? .force("speak") : .auto

        var iterations = 0
        while iterations < maxToolIterations {
            iterations += 1
            let response: BrainResponse
            do {
                response = try await brain.respond(messages: convo, tools: coachTools,
                                                   toolChoice: toolChoice, conversationId: convId)
            } catch {
                // Don't fail completely silently — a 401/429/network storm is otherwise invisible.
                jlog("Jarvis coach: brain request failed on \(reason): \(error.localizedDescription)")
                return .brainError
            }

            // If Stop fired during the (possibly slow) brain round-trip, don't act on the result.
            if Task.isCancelled { jlog("… turn cancelled (stopped) mid-think"); return .cancelled }

            // No tool call → either deliberate silence or a TRUNCATED run. Distinguish them: a
            // truncated response (zero tool calls because reasoning+output blew the token cap) is a
            // bug signal, not a coaching decision.
            guard let call = response.toolCalls.first else {
                if let reasonText = response.incompleteReason {
                    jlog("⚠️ response truncated (\(reasonText)) — not deliberate silence")
                    // Forcing `speak` only constrains WHICH tool, not that output is emitted: a
                    // reasoning model can still truncate to zero items. Never leave a direct address
                    // unanswered — fall back to a spoken acknowledgement.
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
                // off the cooperative pool so it doesn't stall a pool thread while holding the
                // single in-flight slot.
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
                    // The conversation already holds the model's function_call; send only the tool
                    // result (+ image) as the next input.
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

            case .speak(_, let text):
                jlog("💬 \(text)")
                overlay.render(text, maxSentences: config.maxSentences,
                               perSentenceSeconds: config.sentenceDisplaySeconds)
                // Direct replies count toward the direct ceiling but don't start the ambient
                // cooldown (a reply shouldn't mute the next coaching nudge); ambient tips do.
                if reason.isDirectAddress { guardrails.noteDirectAddress() } else { guardrails.noteSpoke() }
                onSpoke?()
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
