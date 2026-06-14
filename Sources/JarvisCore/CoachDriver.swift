import Foundation

/// The event loop. On a trigger, enforces guardrails, calls the brain with the timestamped
/// transcript + timing context and the tool set, and routes tool calls (capture_screen, speak).
/// All judgment lives in the model; this just wires events to tool calls and enforces safety.
public final class CoachDriver: @unchecked Sendable {
    private let config: Config
    private let transcript: RollingTranscript
    private let guardrails: Guardrails
    private let brain: BrainClient
    private let screen: ScreenCapturing
    private let overlay: OverlayRendering
    private let clock: Clock
    private let sessionStart: TimeInterval

    /// Optional hook for the menu-bar session counter.
    public var onSpoke: (@Sendable () -> Void)?

    /// Safety backstop against a pathological model that loops on capture_screen forever.
    private let maxToolIterations = 4

    public init(config: Config, transcript: RollingTranscript, guardrails: Guardrails,
                brain: BrainClient, screen: ScreenCapturing, overlay: OverlayRendering, clock: Clock) {
        self.config = config
        self.transcript = transcript
        self.guardrails = guardrails
        self.brain = brain
        self.screen = screen
        self.overlay = overlay
        self.clock = clock
        self.sessionStart = clock.now()
    }

    public func handleTrigger(_ reason: TriggerReason) async {
        guard guardrails.allow() else { return }

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

        var iterations = 0
        while iterations < maxToolIterations {
            iterations += 1
            let response: BrainResponse
            do {
                response = try await brain.respond(messages: convo, tools: coachTools)
            } catch {
                return // network/model error: fail silent this turn
            }

            // No tool call → stay silent.
            guard let call = response.toolCalls.first else { return }

            switch call {
            case .captureScreen(let callId):
                // Replay the assistant tool-call turn before the tool result (Chat Completions contract).
                convo.append(.assistantToolCalls(response.rawToolCalls))
                if let img = screen.capture() {
                    convo.append(.init(role: .tool, text: "screenshot captured", toolCallId: callId))
                    convo.append(.userImage(img))
                } else {
                    convo.append(.init(role: .tool, text: "screenshot failed", toolCallId: callId))
                }
                continue // let the model reason over the image

            case .speak(_, let text):
                // Re-check guardrails right before emitting (state may have changed during await).
                guard guardrails.allow() else { return }
                overlay.render(text, maxSentences: config.maxSentences,
                               perSentenceSeconds: config.sentenceDisplaySeconds)
                guardrails.noteSpoke()
                onSpoke?()
                return
            }
        }
    }
}
