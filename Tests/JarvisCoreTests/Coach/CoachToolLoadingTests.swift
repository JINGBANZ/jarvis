import Foundation
import Testing
@testable import JarvisCore

/// Records every Activity event a coaching attempt produced, in order.
///
/// `@unchecked Sendable` is safe for the same reason as `ScriptedBrain`: the only mutable state is
/// accessed under `lock`.
final class RecordingActivity: ActivityEventRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ActivityEvent] = []
    var events: [ActivityEvent] { lock.withLock { _events } }
    var kinds: [ActivityEvent.Kind] { events.map(\.rendered.kind) }
    func record(_ event: ActivityEvent, at date: Date) {
        lock.withLock { _events.append(event) }
    }
}

/// A deferred tool becomes callable when — and only when — the model asks for it, and a load is
/// remembered only by an attempt that finished a turn.
@Suite(.serialized) struct CoachToolLoadingTests {
    private let prepConfigured = CoachCapabilities.compose(
        disabledTools: [], prepSourcesConfigured: true)

    private func loadCall(_ name: String, id: String = "l1") -> BrainResponse {
        .init(toolCalls: [.loadTool(callId: id, name: name)],
              rawToolCalls: [RawToolCall(id: id, name: "load_tool",
                                         argumentsJSON: #"{"name":"\#(name)"}"#)])
    }

    private var speak: BrainResponse {
        .init(toolCalls: [.speak(callId: "s1", lines: ["Name the constraint first."])],
              rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                         argumentsJSON: #"{"lines":["Name the constraint first."]}"#)])
    }

    private func makeDriver(
        brain: BrainClient,
        capabilities: CoachCapabilities,
        prepMaterial: (any PrepMaterialSearching)? = nil,
        activity: (any ActivityEventRecording)? = nil
    ) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let target = BrainTarget(
            provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [.init(target: target, brain: brain)]),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(now: 100),
            automaticAttemptDelay: { _ in },
            activity: activity,
            capabilities: capabilities,
            prepMaterial: prepMaterial)
        return (driver, transcript)
    }

    private func makeRunner(
        capabilities: CoachCapabilities,
        activity: (any ActivityEventRecording)? = nil
    ) -> CoachAttemptRunner {
        CoachAttemptRunner(
            config: .default, transcript: RollingTranscript(), screen: FakeScreen(),
            overlay: FakeOverlay(), clock: ManualClock(now: 100), sessionStart: 0,
            coachingAttempts: nil, activity: activity, ledger: CoachTranscriptLedger(),
            capabilities: capabilities)
    }

    private func run(
        _ runner: CoachAttemptRunner, brain: BrainClient,
        prepMaterial: (any PrepMaterialSearching)? = nil
    ) async -> CoachAttemptRunner.AttemptResult {
        var work = CoachAttemptRunner.PendingCoachingWork(reason: .turnEnd)
        work.prepNotesObservation = .user("a question is pending")
        let target = BrainTarget(
            provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        return await runner.runAttempt(work, using: .init(
            plan: .default, routeRevision: 0, routeTopologyRevision: 0, routeIndex: 0,
            target: target, brain: brain, summarizer: nil, onSelected: nil,
            prepMaterial: prepMaterial)).result
    }

    /// The whole point of the step: catalog, load, use, coach — one attempt, one turn.
    @Test func aLoadedToolIsUsableInTheSameAttempt() async throws {
        let search = FakePrepMaterialSearch(results: [PrepMaterialSearchResult(
            sourceDisplayName: "system-design.md", text: "token bucket notes")])
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [
            loadCall("search_prep_notes"),
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "rate limiter")],
                  rawToolCalls: [RawToolCall(id: "p1", name: "search_prep_notes",
                                             argumentsJSON: #"{"query":"rate limiter"}"#)]),
            speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: prepConfigured, prepMaterial: search, activity: activity)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        // The load's result carries the schema and the guidance the prompt no longer holds.
        let result = try #require(brain.calls[1].first { $0.toolCallId == "l1" })
        #expect(result.text?.contains(searchPrepNotesTool.parametersJSON) == true)
        #expect(result.text?.contains("# Prep material") == true)
        // Declared only after the load: the first request offered the loader, not the tool.
        #expect(!brain.offeredTools[0].map(\.name).contains("search_prep_notes"))
        #expect(brain.offeredTools[1].map(\.name).contains("search_prep_notes"))
        #expect(search.queries == ["rate limiter"])
        #expect(activity.kinds == [.capabilityLoaded, .prepNotesSearched, .tip])
        #expect(brain.requestContexts.compactMap { $0 }.map(\.phase)
            == [.initial, .loadToolContinuation, .searchPrepNotesContinuation])
    }

    /// Loading twice returns a pointer to the conversation, never the body again.
    @Test func aSecondLoadIsAnsweredWithoutRepeatingTheGuidance() async throws {
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [
            loadCall("search_prep_notes"), loadCall("search_prep_notes", id: "l2"), speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: prepConfigured,
            prepMaterial: FakePrepMaterialSearch(), activity: activity)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let second = try #require(brain.calls[2].first { $0.toolCallId == "l2" })
        #expect(second.text == JarvisPrompts.Coach.loadToolAlreadyLoaded("search_prep_notes"))
        #expect(second.text?.contains("# Prep material") == false)
        #expect(activity.kinds == [.capabilityLoaded, .tip])
    }

    /// An unknown name is a plain answer, never an attempt failure: the turn still coaches.
    @Test func anUnknownLoadNameIsAnsweredAndTheTurnContinues() async throws {
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [loadCall("read_my_email"), speak])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: prepConfigured,
            prepMaterial: FakePrepMaterialSearch(), activity: activity)
        transcript.append(.init(speaker: .me, text: "what should I say here", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let result = try #require(brain.calls[1].first { $0.toolCallId == "l1" })
        #expect(result.text == JarvisPrompts.Coach.toolUnavailable("read_my_email"))
        #expect(activity.kinds == [.tip])
    }

    /// A load belongs to the attempt that made it. An attempt that never commits leaves nothing
    /// behind, so "already loaded" always points at a conversation the model can actually see.
    @Test func aLoadInAFailedAttemptIsMadeAgainByTheNext() async throws {
        let runner = makeRunner(capabilities: prepConfigured)
        let brain = ScriptedBrain(script: [
            loadCall("search_prep_notes"),
            .init(toolCalls: [], incompleteReason: "max_output_tokens"),
            loadCall("search_prep_notes", id: "l2"),
            speak,
        ])

        guard case .failed(let outcome, _, _) = await run(runner, brain: brain) else {
            Issue.record("expected the truncated response to fail the attempt"); return
        }
        #expect(outcome == .truncated)

        guard case .completed(let second) = await run(runner, brain: brain) else {
            Issue.record("expected the second attempt to commit a turn"); return
        }
        #expect(second == .spoke)
        let result = try #require(brain.calls[3].first { $0.toolCallId == "l2" })
        #expect(result.text?.contains(searchPrepNotesTool.parametersJSON) == true)
    }

    /// A committed load stays loaded: the next attempt does not spend a round trip on it.
    @Test func aCommittedLoadIsRememberedByTheNextAttempt() async throws {
        let runner = makeRunner(capabilities: prepConfigured)
        let brain = ScriptedBrain(script: [
            loadCall("search_prep_notes"), speak, loadCall("search_prep_notes", id: "l2"), speak,
        ])

        _ = await run(runner, brain: brain)
        _ = await run(runner, brain: brain)

        let second = try #require(brain.calls[3].first { $0.toolCallId == "l2" })
        #expect(second.text == JarvisPrompts.Coach.loadToolAlreadyLoaded("search_prep_notes"))
        // The tool was declared from this attempt's first request, without loading again.
        #expect(brain.offeredTools[2].map(\.name).contains("search_prep_notes"))
    }

    /// A switched-off tool stays switched off, whatever a text-protocol model emits.
    @Test func aCallToAToolTheSessionDoesNotOfferIsRefused() async throws {
        let search = FakePrepMaterialSearch()
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "rate limiter")],
                  rawToolCalls: [RawToolCall(id: "p1", name: "search_prep_notes",
                                             argumentsJSON: #"{"query":"rate limiter"}"#)]),
            speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain,
            capabilities: .compose(disabledTools: ["search_prep_notes"],
                                   prepSourcesConfigured: true),
            prepMaterial: search, activity: activity)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let result = try #require(brain.calls[1].first { $0.toolCallId == "p1" })
        #expect(result.text == JarvisPrompts.Coach.toolUnavailable("search_prep_notes"))
        #expect(search.queries.isEmpty)
        #expect(activity.kinds == [.tip])
    }

    /// Offered but called before loading: only a text protocol can do this, and the call is honest,
    /// so it runs rather than costing the turn a round trip.
    @Test func aDeferredToolCalledBeforeLoadingStillRuns() async throws {
        let search = FakePrepMaterialSearch(results: [PrepMaterialSearchResult(
            sourceDisplayName: "system-design.md", text: "token bucket notes")])
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "rate limiter")],
                  rawToolCalls: [RawToolCall(id: "p1", name: "search_prep_notes",
                                             argumentsJSON: #"{"query":"rate limiter"}"#)]),
            speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: prepConfigured, prepMaterial: search)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        #expect(search.queries == ["rate limiter"])
        let result = try #require(brain.calls[1].first { $0.toolCallId == "p1" })
        #expect(result.text?.contains("token bucket notes") == true)
    }

    /// No port means the index is still building, or finished with nothing usable in any source.
    /// Both answer the same way: the model was told the notes exist, so it is told plainly that they
    /// are not there — not that they were read and found wanting, and not by failing the attempt.
    @Test func searchingWithNoIndexAnswersAndKeepsCoaching() async throws {
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "rate limiter")],
                  rawToolCalls: [RawToolCall(id: "p1", name: "search_prep_notes",
                                             argumentsJSON: #"{"query":"rate limiter"}"#)]),
            speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: prepConfigured, prepMaterial: nil, activity: activity)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let result = try #require(brain.calls[1].first { $0.toolCallId == "p1" })
        #expect(result.text == JarvisPrompts.Coach.prepNotesUnavailable)
        #expect(activity.kinds == [.prepNotesUnavailable, .tip])
    }

    /// Room for the longest sensible chain plus two spare responses, and a hard stop after that.
    @Test(arguments: [(6, true), (7, false)])
    func theToolLoopAllowsSevenResponses(captures: Int, commits: Bool) async {
        let capture = BrainResponse(
            toolCalls: [.captureScreen(callId: "c1")],
            rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")])
        let runner = makeRunner(capabilities: .default)
        let brain = ScriptedBrain(script: Array(repeating: capture, count: captures) + [speak])

        let result = await run(runner, brain: brain)

        if commits {
            guard case .completed(let outcome) = result else {
                Issue.record("expected the seventh response to be allowed"); return
            }
            #expect(outcome == .spoke)
        } else {
            guard case .failed(let outcome, _, _) = result else {
                Issue.record("expected an eighth response to exhaust the loop"); return
            }
            #expect(outcome == .exhausted)
        }
        #expect(brain.calls.count == min(captures + 1, 7))
    }
}
