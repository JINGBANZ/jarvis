import Foundation
import Testing
@testable import JarvisCore

/// A screen whose `capture()` always fails (returns nil), to exercise the manual-hint path when no
/// screenshot is available — the hint must still be forced from transcript/conversation context.
private final class FailingScreen: ScreenCapturing, @unchecked Sendable {
    private(set) var captureCount = 0
    func capture() -> String? { captureCount += 1; return nil }
}

/// The on-demand hint shortcut (`.manualHint`): the driver itself captures the screenshot and
/// injects it into the FIRST request, then forces the `speak` tool — so a hint comes back in ONE
/// brain round trip instead of the model asking for `capture_screen` and reasoning on a second trip.
@Suite struct CoachDriverManualHintTests {
    private func makeDriver(brain: BrainClient, screen: ScreenCapturing, overlay: OverlayRendering,
                            clock: Clock) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            brain: brain, screen: screen, overlay: overlay, clock: clock
        )
        return (driver, transcript)
    }

    /// The whole point of the feature: one trip. The driver captures the screen itself, the single
    /// request carries the image, the model is forced to speak, and a hint is rendered.
    @Test func manualHintInjectsScreenshotAndForcesSpeakInOneTrip() async {
        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "s1", lines: ["Use a hash map to remember what you've seen."])],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                             argumentsJSON: #"{"lines":["Use a hash map to remember what you've seen."]}"#)]),
        ])
        let screen = FakeScreen()
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, screen: screen, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "I'm stuck on this two-sum problem", at: 100))

        let outcome = await driver.handleTrigger(.manualHint)

        #expect(outcome == .spoke)
        #expect(screen.captureCount == 1)                              // the DRIVER captured, not the brain
        #expect(brain.calls.count == 1)                               // ONE trip — no capture_screen round trip
        #expect(brain.toolChoices.last == .force("speak"))            // forced to reply
        #expect(brain.calls[0].contains { $0.imageBase64JPEG != nil })// the screenshot rode along in the first request
        #expect(overlay.rendered == [["Use a hash map to remember what you've seen."]])
    }

    /// If the screenshot fails, the hint is still forced from transcript/conversation context — one
    /// trip, still `.spoke`, just no image attached.
    @Test func manualHintForcesSpeakEvenWhenScreenshotFails() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "s1", lines: ["Talk me through your current approach."])]),
        ])
        let screen = FailingScreen()
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: screen, overlay: overlay, clock: clock)

        let outcome = await driver.handleTrigger(.manualHint)

        #expect(outcome == .spoke)
        #expect(screen.captureCount == 1)                             // attempted...
        #expect(brain.calls.count == 1)                              // ...still one trip
        #expect(brain.toolChoices.last == .force("speak"))
        #expect(!brain.calls[0].contains { $0.imageBase64JPEG != nil })// no image, capture failed
        #expect(overlay.rendered == [["Talk me through your current approach."]])
    }
}
