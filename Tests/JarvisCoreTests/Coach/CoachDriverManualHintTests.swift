import Foundation
import Testing
@testable import JarvisCore

/// A screen whose `capture()` always fails (returns nil), to exercise the manual-hint path when no
/// screenshot is available — the hint must still be forced from transcript/conversation context.
private final class FailingScreen: ScreenCapturing, @unchecked Sendable {
    private(set) var captureCount = 0
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? { captureCount += 1; return nil }
    func cancelCapture() {}
}

/// The on-demand hint shortcut (`.manualHint`): the driver itself captures the screenshot and
/// injects it into the FIRST request, then forces the `speak` tool — so a hint comes back in ONE
/// brain round trip instead of the model asking for `capture_screen` and reasoning on a second trip.
/// Serialized: `hintCancellationTerminatesTheCapture` parks a `GatedScreen` whose `capture()`
/// blocks until the test releases it, and the driver runs that capture on a `Task.detached` —
/// i.e. on the width-limited cooperative pool. Only three tests in the repository park a pool
/// thread this way, and a CI runner has three of those threads, so letting them overlap can hold
/// every thread at once with nothing left to run a release path. Cap this suite at one.
@Suite(.serialized) struct CoachDriverManualHintTests {
    private func makeDriver(brain: BrainClient, screen: ScreenCapturing, overlay: OverlayRendering,
                            clock: Clock) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let target = BrainTarget(
            provider: .openAI,
            modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [
                ConfiguredBrainTarget(target: target, brain: brain),
            ]),
            screen: screen, overlay: overlay, clock: clock,
            automaticAttemptDelay: { _ in },
            activity: nil
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
        // The "simulate a message as the user" half: the manual-hint prompt AND the live transcript
        // both reach the brain in that single request.
        let userText = brain.calls[0].compactMap { $0.text }.joined(separator: " ")
        #expect(userText.contains("hint shortcut"))   // the synthetic manual-hint message
        #expect(userText.contains("two-sum"))         // …alongside the real transcript context
    }

    /// D2 (OCR sidecar) on the pre-injected manual-hint path: there's no tool result to carry the
    /// recognized text, so it rides as its own user message in the SAME single trip as the image.
    @Test func manualHintCarriesRecognizedTextAlongsideTheScreenshot() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "s1", lines: ["groupEnd can be null on the last group."])],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                             argumentsJSON: #"{"lines":["groupEnd can be null on the last group."]}"#)]),
        ])
        let screen = FakeScreen(recognizedText: "ListNode next = groupEnd.next;")
        let (driver, _) = makeDriver(brain: brain, screen: screen,
                                     overlay: FakeOverlay(), clock: ManualClock(now: 100))

        let outcome = await driver.handleTrigger(.manualHint)

        #expect(outcome == .spoke)
        #expect(brain.calls.count == 1)   // OCR must not cost an extra trip
        #expect(brain.calls[0].contains { $0.imageBase64JPEG != nil })
        let userText = brain.calls[0].compactMap { $0.text }.joined(separator: "\n")
        #expect(userText.contains("ListNode next = groupEnd.next;"))
        #expect(userText.contains("may contain errors"))
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

    /// Stop firing while the manual-hint screenshot is in flight cancels the capture adapter and
    /// aborts before any brain request or stale tip. Reuses `GatedScreen`.
    @Test func manualHintCancelDuringCaptureAbortsBeforeAnyBrainCall() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "s", lines: ["stale tip from the stopped run"])]),
        ])
        let screen = GatedScreen()
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, screen: screen, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "here is my code", at: 0))

        let task = Task { await driver.handleTrigger(.manualHint) }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { screen.entered.wait(); cont.resume() }   // capture in flight
        }
        task.cancel()                                         // Stop fires mid-capture

        #expect(await task.value == .cancelled)
        #expect(screen.captureCount == 1)        // captured once...
        #expect(screen.cancelCount == 1)         // ...and cancelled through the capture adapter
        #expect(overlay.rendered.isEmpty)        // ...but never rendered a tip after Stop
        #expect(brain.calls.isEmpty)             // and the guard fires before any brain.respond call
    }
}
