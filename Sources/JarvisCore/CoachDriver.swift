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

    public func handleTrigger(_ reason: TriggerReason) async {
        guard beginHandling() else { return }   // one interjection at a time
        defer { endHandling() }

        jlog(triggerLabel(reason))

        guard guardrails.allow() else {
            jlog("… held back (cooldown or rate cap)")
            return
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

        var iterations = 0
        while iterations < maxToolIterations {
            iterations += 1
            let response: BrainResponse
            do {
                response = try await brain.respond(messages: convo, tools: coachTools)
            } catch {
                // Don't fail completely silently — a 401/429/network storm is otherwise invisible.
                jlog("Jarvis coach: brain request failed on \(reason): \(error.localizedDescription)")
                return
            }

            // No tool call → stay silent.
            guard let call = response.toolCalls.first else {
                jlog("… nothing useful to add, staying silent")
                return
            }

            switch call {
            case .captureScreen(let callId):
                jlog("👁 looking at your screen")
                // Replay the model's function call, then the tool result + the screenshot image.
                convo.append(.assistantToolCalls(response.rawToolCalls))
                if let img = screen.capture() {
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
                guardrails.noteSpoke()
                onSpoke?()
                return
            }
        }
    }

    /// A short, human-readable marker for why the loop woke up — shown in the activity viewer.
    private func triggerLabel(_ reason: TriggerReason) -> String {
        switch reason {
        case .turnEnd:               return "🗣 you finished a thought"
        case .silence(let secs):     return "🤫 quiet for \(Int(secs))s"
        }
    }
}
