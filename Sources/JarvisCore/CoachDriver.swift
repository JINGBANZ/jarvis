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

        var convo: [ChatMessage] = [
            .system(coachSystemPrompt),
            .user("""
            Recent transcript (timestamped):
            \(transcript.renderWindow(seconds: config.transcriptWindowSeconds, now: now))

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
                response = try await brain.respond(messages: convo, tools: coachTools, toolChoice: toolChoice)
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
                    return .truncated
                }
                jlog("… nothing useful to add, staying silent")
                return .silentByModel
            }

            switch call {
            case .captureScreen(let callId):
                jlog("👁 looking at your screen")
                // Replay the model's function call, then the tool result + the screenshot image.
                convo.append(.assistantToolCalls(response.rawToolCalls))
                // ScreenCaptureCLI shells out to `screencapture` and blocks for 100s of ms; run it
                // off the cooperative pool so it doesn't stall a pool thread while holding the
                // single in-flight slot.
                let screen = self.screen
                if let img = await Task.detached(priority: .userInitiated, operation: { screen.capture() }).value {
                    convo.append(.init(role: .tool, text: "screenshot captured", toolCallId: callId))
                    convo.append(.userImage(img))
                } else {
                    convo.append(.init(role: .tool, text: "screenshot failed", toolCallId: callId))
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
        return .exhausted
    }
}

/// The terminal outcome of a coaching turn — surfaced so every "quiet" path is observable instead
/// of a silent `return`. Tuning cooldown / VAD / silence thresholds depends on knowing WHICH of
/// these fired.
public enum TurnOutcome: Sendable, Equatable {
    case spoke            // rendered a coaching tip
    case silentByModel    // model deliberately called no tool
    case truncated        // response cut off by the token cap (NOT a real silence decision)
    case heldBack         // guardrail blocked: cooldown, rate cap, or mute
    case busy             // a turn was already in flight; this trigger was dropped
    case cancelled        // Stop cancelled the turn
    case brainError       // the brain request threw (401/429/network)
    case exhausted        // ran the tool loop to the cap without a terminal speak
}
