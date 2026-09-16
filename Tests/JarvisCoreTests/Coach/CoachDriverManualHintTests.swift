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
/// injects it into the FIRST request, so the model never spends a round trip on `capture_screen`.
/// A press joins the tool loop: it may load a skill or tool and search prep notes, never stays
/// silent or captures again, and its last permitted response is forced to `speak`. With nothing to
/// load, a hint comes back in ONE brain round trip with `speak` forced.
/// Serialized: `hintCancellationTerminatesTheCapture` parks a `GatedScreen` whose `capture()`
/// blocks until the test releases it, and the driver runs that capture on a `Task.detached` —
/// i.e. on the width-limited cooperative pool. Only three tests in the repository park a pool
/// thread this way, and a CI runner has three of those threads, so letting them overlap can hold
/// every thread at once with nothing left to run a release path. Cap this suite at one.
@Suite(.serialized) struct CoachDriverManualHintTests {
    private func makeDriver(brain: BrainClient, screen: ScreenCapturing, overlay: OverlayRendering,
                            clock: Clock, capabilities: CoachCapabilities = .default,
                            prepMaterial: (any PrepMaterialSearching)? = nil,
                            activity: (any ActivityEventRecording)? = nil)
        -> (CoachDriver, RollingTranscript) {
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
            activity: activity,
            capabilities: capabilities,
            prepMaterial: prepMaterial
        )
        return (driver, transcript)
    }

    /// With nothing to load, the whole point of the feature: one trip. The driver captures the
    /// screen itself, the single request carries the image, the model is forced to speak, and a hint
    /// is rendered.
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
        #expect(brain.toolChoices == [.force("speak")])               // forced to reply
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
        #expect(userText.contains("may misread tokens"))
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

    // MARK: - Loading inside a press

    private let skills = [
        Skill(name: "behavioral", description: "Coaching for behavioral questions.",
              body: "# Behavioral questions\n\nOrganize the answer as STAR."),
        Skill(name: "system-design", description: "Coaching for design questions.",
              body: "# System-design questions\n\nSix stages."),
    ]

    /// What a press may call while `load_skill` has something left: everything but the two
    /// actions a press must never take.
    private let pressWithSkillsLeft = ToolChoice.allowed(["speak", "load_skill"])

    private func loadSkill(_ name: String, id: String = "k1") -> BrainResponse {
        .init(toolCalls: [.loadSkill(callId: id, name: name)],
              rawToolCalls: [RawToolCall(id: id, name: "load_skill",
                                         argumentsJSON: #"{"name":"\#(name)"}"#)])
    }

    private var speak: BrainResponse {
        .init(toolCalls: [.speak(callId: "s1", lines: ["Start from the read path."])],
              rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                         argumentsJSON: #"{"lines":["Start from the read path."]}"#)])
    }

    /// The first press of a session, before anything loaded: the press loads the skill its question
    /// needs and coaches with it, in one attempt, on the screenshot it already took.
    @Test func aPressLoadsTheSkillItNeedsAndSpeaksInOneAttempt() async throws {
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [loadSkill("system-design"), speak])
        let screen = FakeScreen()
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(
            brain: brain, screen: screen, overlay: overlay, clock: ManualClock(now: 100),
            capabilities: .compose(disabledTools: [], prepSourcesConfigured: false, skills: skills),
            activity: activity)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(screen.captureCount == 1)
        #expect(brain.toolChoices == [pressWithSkillsLeft, pressWithSkillsLeft])
        let result = try #require(brain.calls[1].first { $0.toolCallId == "k1" })
        #expect(result.text?.contains("Six stages.") == true)
        #expect(overlay.rendered == [["Start from the read path."]])
        #expect(activity.kinds == [.manualHint, .screenViewed, .capabilityLoaded, .tip])
    }

    /// Once nothing is left to load and no loaded tool is callable, the next response is the plain
    /// forced `speak`.
    @Test func aPressForcesSpeakOnceNothingIsLeftToLoad() async {
        let brain = ScriptedBrain(script: [loadSkill("behavioral"), speak])
        let (driver, _) = makeDriver(
            brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(now: 100),
            capabilities: .compose(disabledTools: [], prepSourcesConfigured: false,
                                   skills: [skills[0]]))

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.toolChoices == [pressWithSkillsLeft, .force("speak")])
    }

    /// A press never runs out of responses: the one at the cap is forced to `speak`, so the model's
    /// last word is a hint rather than an exhausted attempt.
    @Test func theResponseAtTheCapOfAPressIsForcedToSpeak() async {
        let repeatedLoads = (1...6).map { loadSkill("behavioral", id: "k\($0)") }
        let brain = ScriptedBrain(script: repeatedLoads + [speak])
        let (driver, _) = makeDriver(
            brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(now: 100),
            capabilities: .compose(disabledTools: [], prepSourcesConfigured: false, skills: skills))

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.toolChoices == Array(repeating: pressWithSkillsLeft, count: 6) + [.force("speak")])
    }

    /// Prep notes are the other thing a press may reach for: load the tool, search, then speak.
    @Test func aPressMaySearchPrepNotesBeforeSpeaking() async {
        let search = FakePrepMaterialSearch(results: [PrepMaterialSearchResult(
            sourceDisplayName: "behavioral.md", text: "the migration I led")])
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.loadTool(callId: "l1", name: "search_prep_notes")],
                  rawToolCalls: [RawToolCall(id: "l1", name: "load_tool",
                                             argumentsJSON: #"{"name":"search_prep_notes"}"#)]),
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "disagreement")],
                  rawToolCalls: [RawToolCall(id: "p1", name: "search_prep_notes",
                                             argumentsJSON: #"{"query":"disagreement"}"#)]),
            speak,
        ])
        let (driver, _) = makeDriver(
            brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(now: 100),
            capabilities: .compose(disabledTools: [], prepSourcesConfigured: true),
            prepMaterial: search, activity: activity)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.toolChoices == [
            .allowed(["speak", "load_tool"]),
            .allowed(["speak", "search_prep_notes"]),
            .allowed(["speak", "search_prep_notes"]),
        ])
        #expect(search.queries == ["disagreement"])
        #expect(activity.kinds
            == [.manualHint, .screenViewed, .capabilityLoaded, .prepNotesSearched, .tip])
    }

    /// A load a press made is the session's once the press speaks, exactly as an automatic one is.
    @Test func aLoadMadeByAPressCommitsToTheSession() async throws {
        let brain = ScriptedBrain(script: [
            loadSkill("behavioral"), speak, loadSkill("behavioral", id: "k2"), speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(now: 100),
            capabilities: .compose(disabledTools: [], prepSourcesConfigured: false, skills: skills))

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        transcript.append(.init(speaker: .them, text: "Tell me about a conflict you had.", at: 101))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        #expect(brain.toolChoices[2] == .required)
        let again = try #require(brain.calls[3].first { $0.toolCallId == "k2" })
        #expect(again.text == JarvisPrompts.Coach.loadSkillAlreadyLoaded("behavioral"))
    }
}
