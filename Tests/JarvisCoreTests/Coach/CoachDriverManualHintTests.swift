import Foundation
import Testing
@testable import JarvisCore

/// @unchecked: `captureCount` is read only after the awaited trigger returns.
private final class FailingScreen: ScreenCapturing, @unchecked Sendable {
    private(set) var captureCount = 0
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? { captureCount += 1; return nil }
    func cancelCapture() {}
}

/// Serialized: a parked `GatedScreen` capture holds a cooperative pool thread, and overlapping
/// parked captures can take every thread on a three-thread CI runner.
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
        #expect(screen.captureCount == 1)
        #expect(brain.calls.count == 1)
        #expect(brain.toolChoices == [.force("speak")])
        #expect(brain.calls[0].contains { $0.imageBase64JPEG != nil })
        #expect(overlay.rendered == [["Use a hash map to remember what you've seen."]])
        let userText = brain.calls[0].compactMap { $0.text }.joined(separator: " ")
        #expect(userText.contains("hint shortcut"))
        #expect(userText.contains("two-sum"))
    }

    @Test func manualHintIncludesSpeechFinalizedDuringCaptureWithoutDuplicateAttempt() async throws {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "answer", lines: ["O(1) amortized per event."])]),
            .init(toolCalls: [.staySilent(callId: "duplicate")]),
        ])
        let screen = GatedScreen()
        let (driver, transcript) = makeDriver(
            brain: brain, screen: screen, overlay: FakeOverlay(), clock: ManualClock())
        let task = Task { await driver.handleTrigger(.manualHint) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { screen.entered.wait(); continuation.resume() }
        }
        let boundary = transcript.append(.init(
            speaker: .me, text: "What is the time complexity for this new approach?", at: 1))
        #expect(await driver.handleTrigger(.turnEnd, transcriptBoundary: boundary) == .busy)
        screen.release.signal()

        #expect(await task.value == .spoke)
        let request = try #require(brain.calls.first)
        #expect(request.contains { ($0.text ?? "").contains("What is the time complexity") })
        #expect(brain.calls.count == 1)
        #expect(await driver.handleTrigger(.turnEnd, transcriptBoundary: boundary) == .busy)
        #expect(brain.calls.count == 1)
    }

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
        #expect(brain.calls.count == 1)
        #expect(brain.calls[0].contains { $0.imageBase64JPEG != nil })
        let userText = brain.calls[0].compactMap { $0.text }.joined(separator: "\n")
        #expect(userText.contains("ListNode next = groupEnd.next;"))
        #expect(userText.contains("may misread tokens"))
    }

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
        #expect(screen.captureCount == 1)
        #expect(brain.calls.count == 1)
        #expect(brain.toolChoices.last == .force("speak"))
        #expect(!brain.calls[0].contains { $0.imageBase64JPEG != nil })
        #expect(overlay.rendered == [["Talk me through your current approach."]])
    }

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
            DispatchQueue.global().async { screen.entered.wait(); cont.resume() }
        }
        task.cancel()

        #expect(await task.value == .cancelled)
        #expect(screen.captureCount == 1)
        #expect(screen.cancelCount == 1)
        #expect(overlay.rendered.isEmpty)
        #expect(brain.calls.isEmpty)
    }

    // MARK: - Loading inside a press

    private let skills = [
        Skill(name: "behavioral", description: "Coaching for behavioral questions.",
              body: "# Behavioral questions\n\nOrganize the answer as STAR."),
        Skill(name: "system-design", description: "Coaching for design questions.",
              body: "# System-design questions\n\nSix stages."),
    ]

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

    @Test func aPressForcesSpeakOnceNothingIsLeftToLoad() async {
        let brain = ScriptedBrain(script: [loadSkill("behavioral"), speak])
        let (driver, _) = makeDriver(
            brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(now: 100),
            capabilities: .compose(disabledTools: [], prepSourcesConfigured: false,
                                   skills: [skills[0]]))

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.toolChoices == [pressWithSkillsLeft, .force("speak")])
    }

    @Test func theResponseAtTheCapOfAPressIsForcedToSpeak() async {
        let repeatedLoads = (1...6).map { loadSkill("behavioral", id: "k\($0)") }
        let brain = ScriptedBrain(script: repeatedLoads + [speak])
        let (driver, _) = makeDriver(
            brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(now: 100),
            capabilities: .compose(disabledTools: [], prepSourcesConfigured: false, skills: skills))

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.toolChoices == Array(repeating: pressWithSkillsLeft, count: 6) + [.force("speak")])
    }

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
