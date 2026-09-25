import Foundation
import Testing
@testable import JarvisCore
// The content-filter test streams through the real OpenAI decoder.
import JarvisBrainProviders

/// What the overlay saw, in order. @unchecked: `lock` guards the log, which the main actor writes.
private final class ProgressRecordingOverlay: OverlayRendering, @unchecked Sendable {
    enum Event: Equatable {
        case progress(BrainReplyProgress)
        case withdraw
        case deliver(lines: [String], detail: String?)
    }

    private let lock = NSLock()
    private var log: [Event] = []
    var events: [Event] { lock.withLock { log } }
    var snapshots: [BrainReplyProgress] {
        events.compactMap { if case .progress(let snapshot) = $0 { snapshot } else { nil } }
    }
    var delivered: [[String]] {
        events.compactMap { if case .deliver(let lines, _) = $0 { lines } else { nil } }
    }

    @MainActor var acceptsDetail: Bool { true }

    func render(_ lines: [String]) {}

    @MainActor func deliver(_ lines: [String], detail: ReplyDetail?) -> ReplyDetail? {
        lock.withLock { log.append(.deliver(lines: lines, detail: detail?.deliveredMarkdown)) }
        return detail
    }

    @MainActor func showReplyProgress(_ progress: BrainReplyProgress?) {
        lock.withLock { log.append(progress.map(Event.progress) ?? .withdraw) }
    }
}

/// Streams each turn's argument prefixes to the attempt's sink before its scripted outcome.
/// @unchecked: `lock` guards the call log.
private final class StreamingBrain: BrainClient, @unchecked Sendable {
    enum Outcome {
        case reply(BrainResponse)
        case failure(any Error)
        /// Waits to be cancelled, as a byte stream does when Stop cancels the attempt.
        case hang
    }

    struct Turn {
        var call = speakToolName
        var prefixes: [String] = []
        var outcome: Outcome
    }

    private let lock = NSLock()
    private var storedCalls: [[ChatMessage]] = []
    private let turns: [Turn]
    var calls: [[ChatMessage]] { lock.withLock { storedCalls } }

    init(turns: [Turn]) { self.turns = turns }

    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        try await respond(messages: messages, progress: nil)
    }

    func makeConversation(progress: ToolCallProgressSink?) async throws -> any BrainConversation {
        Conversation(brain: self, progress: progress)
    }

    fileprivate func respond(messages: [ChatMessage], progress: ToolCallProgressSink?) async throws -> BrainResponse {
        let index = lock.withLock { () -> Int in
            storedCalls.append(messages)
            return storedCalls.count - 1
        }
        let turn = turns[min(index, turns.count - 1)]
        for prefix in turn.prefixes {
            _ = progress?(ToolCallDelta(index: 0, name: turn.call, arguments: prefix))
        }
        switch turn.outcome {
        case .reply(let response): return response
        case .failure(let error): throw error
        case .hang:
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
    }

    private struct Conversation: BrainConversation {
        let brain: StreamingBrain
        let progress: ToolCallProgressSink?
        func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
            try await brain.respond(messages: messages, progress: progress)
        }
        func finish() async {}
    }
}

@Suite struct CoachDriverStreamingTests {
    private static let arguments = #"{"lines":["Sort by start.","Then merge overlaps."],"detail":"Keep the last interval as the cursor."}"#
    /// Every scalar-count prefix of the arguments, as a stream of deltas would leave them.
    private static let prefixes: [String] = {
        let scalars = Array(arguments.unicodeScalars)
        return stride(from: 1, through: scalars.count, by: 3).map { String(String.UnicodeScalarView(scalars[..<$0])) }
            + [arguments]
    }()
    /// What the speak reply's own prefixes scan to; coalescing decides which of them paint.
    private static let speakSnapshots = prefixes.compactMap(SpeakArgumentsScanner.progress(in:))
    private static let linesClosed = String(arguments.prefix(#"{"lines":["Sort by start.","Then merge overlaps."],"detail":"Keep the"#.count))

    private func reply(_ raw: RawToolCall..., incompleteReason: String? = nil) -> BrainResponse {
        BrainResponse(
            toolCalls: raw.compactMap { ToolInvocation.parse(callId: $0.id, name: $0.name, argumentsJSON: $0.argumentsJSON) },
            rawToolCalls: raw, incompleteReason: incompleteReason)
    }

    private var speak: BrainResponse {
        reply(RawToolCall(id: "s1", name: speakToolName, argumentsJSON: Self.arguments))
    }

    private var capabilities: CoachCapabilities {
        CoachCapabilities.compose(disabledTools: [], prepSourcesConfigured: false)
    }

    private func makeDriver(brain: BrainClient, overlay: OverlayRendering, activity: (any ActivityEventRecording)? = nil)
        -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let target = BrainTarget(provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [ConfiguredBrainTarget(target: target, brain: brain)]),
            screen: FakeScreen(), overlay: overlay, clock: ManualClock(now: 100),
            automaticAttemptDelay: { _ in }, activity: activity, capabilities: capabilities)
        return (driver, transcript)
    }

    private func runAttempt(_ reason: TriggerReason, brain: BrainClient, overlay: OverlayRendering)
        async -> CoachAttemptRunner.AttemptResult {
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .them, text: "How would you merge intervals?", at: 100))
        let runner = CoachAttemptRunner(
            config: .default, transcript: transcript, screen: FakeScreen(),
            overlay: overlay, clock: ManualClock(now: 100), sessionStart: 0,
            coachingAttempts: nil, activity: nil, ledger: CoachTranscriptLedger(),
            capabilities: capabilities)
        let target = BrainTarget(provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        return await runner.runAttempt(.init(reason: reason), using: .init(
            plan: .default, routeRevision: 0, routeTopologyRevision: 0, routeIndex: 0,
            target: target, brain: brain, summarizer: nil, onSelected: nil, prepMaterial: nil)).result
    }

    /// Coalescing may drop intermediate snapshots, never reorder them.
    private func expectOrdered(_ snapshots: [BrainReplyProgress]) {
        for (earlier, later) in zip(snapshots, snapshots.dropFirst()) {
            #expect(later.closedLines.starts(with: earlier.closedLines), "closed lines only grow")
            #expect(!earlier.linesComplete || later.linesComplete, "lines never reopen")
        }
    }

    @Test func streamedLinesReachTheOverlayInOrderBeforeDeliverFinalizesThem() async throws {
        let overlay = ProgressRecordingOverlay()
        let brain = StreamingBrain(turns: [.init(prefixes: Self.prefixes, outcome: .reply(speak))])
        let (driver, _) = makeDriver(brain: brain, overlay: overlay)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        let events = overlay.events
        let snapshots = overlay.snapshots
        #expect(!snapshots.isEmpty, "the overlay saw the reply before it completed")
        #expect(snapshots.allSatisfy { $0.hasText }, "nothing is painted before the first character")
        expectOrdered(snapshots)
        let last = try #require(snapshots.last)
        #expect(last.closedLines == ["Sort by start.", "Then merge overlaps."])
        #expect(last.linesComplete)
        #expect(last.detailMarkdown == "Keep the last interval as the cursor.")
        #expect(events.last == .deliver(lines: ["Sort by start.", "Then merge overlaps."],
                                        detail: "Keep the last interval as the cursor."))
        #expect(!events.contains(.withdraw), "a delivered reply is never withdrawn")
        #expect(events.firstIndex { if case .deliver = $0 { true } else { false } } == events.count - 1)
    }

    @Test func aFailureBeforeTheLinesCloseWithdrawsAndFails() async {
        let overlay = ProgressRecordingOverlay()
        let brain = StreamingBrain(turns: [.init(
            prefixes: [#"{"lines":["Sort by"#],
            outcome: .failure(URLError(.networkConnectionLost)))])

        guard case .failed(let outcome, _, _) = await runAttempt(.manualHint, brain: brain, overlay: overlay) else {
            Issue.record("expected the attempt to fail"); return
        }
        #expect(outcome == .brainError)
        #expect(overlay.events.last == .withdraw)
        #expect(overlay.delivered.isEmpty)
        #expect(overlay.snapshots.last?.openLine == "Sort by")
    }

    @Test func aFailureAfterTheLinesCloseCommitsTheHintFromTheSnapshot() async throws {
        let overlay = ProgressRecordingOverlay()
        let activity = RecordingActivity()
        let brain = StreamingBrain(turns: [
            .init(prefixes: [Self.linesClosed], outcome: .failure(URLError(.timedOut))),
            .init(outcome: .reply(speak)),
        ])
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, activity: activity)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.calls.count == 1, "no fresh attempt follows a hint the user has read")
        #expect(overlay.events.last == .deliver(lines: ["Sort by start.", "Then merge overlaps."], detail: "Keep the"))
        #expect(!overlay.events.contains(.withdraw))
        #expect(activity.events.contains {
            if case .tip(let lines, let detail) = $0 { lines == ["Sort by start.", "Then merge overlaps."] && detail == "Keep the" } else { false }
        })

        // The committed turn replays the rebuilt call with the detail as read.
        transcript.append(.init(speaker: .them, text: "And the complexity?", at: 101))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        let replayed = try #require(brain.calls[1].flatMap { $0.toolCalls ?? [] }.first { $0.name == speakToolName })
        let object = try #require(JSONSerialization.jsonObject(with: Data(replayed.argumentsJSON.utf8)) as? [String: Any])
        #expect(object["lines"] as? [String] == ["Sort by start.", "Then merge overlaps."])
        #expect(object["detail"] as? String == "Keep the")
        #expect(replayed.id.hasPrefix("runner_"))
        #expect(brain.calls[1].contains { $0.role == .tool && $0.toolCallId == replayed.id })
    }

    /// Claude's `stop_reason: refusal` reaches the runner as a `.rejected` failure: the provider
    /// stopped the reply on purpose, so its closed lines are withdrawn, nothing is committed, and a
    /// fresh attempt follows as after any failure. The target is OpenAI because the runner only
    /// reads the category.
    @Test func aRejectedReplyAfterTheLinesCloseIsWithdrawnAndFails() async throws {
        let overlay = ProgressRecordingOverlay()
        let activity = RecordingActivity()
        let refusal = ProviderFailure(
            source: .brain(.openAI), stage: .response, category: .rejected, disposition: .temporary,
            identity: .init(errorType: "refusal", errorCode: "harmful_content"), message: "")
        let brain = StreamingBrain(turns: [
            .init(prefixes: [Self.linesClosed], outcome: .failure(refusal)),
            .init(prefixes: Self.prefixes, outcome: .reply(speak)),
        ])
        let (driver, _) = makeDriver(brain: brain, overlay: overlay, activity: activity)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.calls.count == 2, "a fresh attempt follows the refusal")
        let events = overlay.events
        let withdraw = try #require(events.firstIndex(of: .withdraw))
        #expect(events[..<withdraw].contains { if case .progress(let snapshot) = $0 { snapshot.linesComplete } else { false } },
                "the withdrawn lines had closed")
        #expect(!brain.calls[1].contains { ($0.toolCalls ?? []).contains { $0.name == speakToolName } },
                "nothing from the refused reply was committed")
        #expect(overlay.delivered == [["Sort by start.", "Then merge overlaps."]])
        #expect(activity.events.filter { if case .tip = $0 { true } else { false } }.count == 1)
    }

    /// OpenAI's safety stop ends a streamed reply `incomplete` with `content_filter`; through the real
    /// accessor it arrives as a rejection, so the closed lines are withdrawn, not kept.
    @Test func aStreamedReplyTheContentFilterStopsAfterItsLinesCloseIsWithdrawn() async throws {
        let events = #"""
        event: response.output_item.added
        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"speak","arguments":""}}

        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":0,"delta":"{\"lines\":[\"Sort by start.\",\"Then merge overlaps.\"],\"detail\":\"Keep the"}

        event: response.incomplete
        data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"content_filter"},"output":[{"type":"function_call","id":"fc_1","call_id":"call_1","name":"speak","arguments":"{\"lines\":[\"Sort by start.\",\"Then merge overlaps.\"],\"detail\":\"Keep the"}]}}


        """#
        let brain = BrainAccessor(
            apiKey: "sk-x", model: BrainModelCatalog.defaultModel(for: .openAI).id, stream: true,
            send: { request in
                let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])
                return (AsyncThrowingStream { continuation in
                    continuation.yield(Data(events.utf8))
                    continuation.finish()
                }, http)
            })
        let overlay = ProgressRecordingOverlay()

        guard case .failed(let outcome, let failure, _) = await runAttempt(.turnEnd, brain: brain, overlay: overlay) else {
            Issue.record("expected the filtered reply to fail"); return
        }
        #expect(outcome == .brainError)
        #expect(failure.category == .rejected)
        #expect(failure.identity.errorCode == "content_filter")
        #expect(overlay.snapshots.last?.linesComplete == true, "the lines had reached the overlay")
        #expect(overlay.delivered.isEmpty)
        #expect(overlay.events.last == .withdraw)
    }

    @Test func anIncompleteReplyAfterTheLinesCloseCommitsTheHint() async {
        let overlay = ProgressRecordingOverlay()
        let brain = StreamingBrain(turns: [.init(
            prefixes: [Self.linesClosed],
            outcome: .reply(reply(incompleteReason: "max_tokens")))])

        guard case .completed(let outcome) = await runAttempt(.turnEnd, brain: brain, overlay: overlay) else {
            Issue.record("expected the closed lines to be spoken"); return
        }
        #expect(outcome == .spoke)
        #expect(overlay.delivered == [["Sort by start.", "Then merge overlaps."]])
    }

    /// An array that closed empty showed no hint, so there is nothing to keep: the attempt fails
    /// like any other and the route is not credited.
    @Test func anEmptyLinesArrayIsNeverCommittedFromTheSnapshot() async {
        let emptyLines = #"{"lines":[],"detail":"Only a detail"#
        for outcome in [StreamingBrain.Outcome.failure(URLError(.timedOut)),
                        .reply(reply(incompleteReason: "max_tokens"))] {
            let overlay = ProgressRecordingOverlay()
            let brain = StreamingBrain(turns: [.init(prefixes: [emptyLines], outcome: outcome)])

            guard case .failed = await runAttempt(.turnEnd, brain: brain, overlay: overlay) else {
                Issue.record("expected the empty array to fail the attempt"); return
            }
            #expect(overlay.delivered.isEmpty)
            #expect(overlay.snapshots.last?.linesComplete == true, "the detail had opened a live entry")
            #expect(overlay.events.last == .withdraw)
        }
    }

    @Test func anIncompleteReplyBeforeTheLinesCloseWithdrawsAndFails() async {
        let overlay = ProgressRecordingOverlay()
        let brain = StreamingBrain(turns: [.init(
            prefixes: [#"{"lines":["Sort by start.","Then"#],
            outcome: .reply(reply(incompleteReason: "max_tokens")))])

        guard case .failed(let outcome, _, _) = await runAttempt(.turnEnd, brain: brain, overlay: overlay) else {
            Issue.record("expected the cut reply to fail"); return
        }
        #expect(outcome == .truncated)
        #expect(overlay.events.last == .withdraw)
        #expect(overlay.delivered.isEmpty)
    }

    @Test func aLoadSkillReplyShowsNothing() async {
        let overlay = ProgressRecordingOverlay()
        let skills = CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: false,
            skills: [Skill(name: "coding", description: "d", body: "b")])
        let transcript = RollingTranscript()
        let target = BrainTarget(provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let brain = StreamingBrain(turns: [
            .init(call: CoachCapabilities.loadSkillName, prefixes: [#"{"na"#, #"{"name":"coding"}"#],
                  outcome: .reply(reply(RawToolCall(id: "l1", name: CoachCapabilities.loadSkillName, argumentsJSON: #"{"name":"coding"}"#)))),
            .init(prefixes: Self.prefixes, outcome: .reply(speak)),
        ])
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [ConfiguredBrainTarget(target: target, brain: brain)]),
            screen: FakeScreen(), overlay: overlay, clock: ManualClock(now: 100),
            automaticAttemptDelay: { _ in }, capabilities: skills)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        // A request that showed nothing has nothing to withdraw, and must not wait on the main
        // actor to do so.
        #expect(!overlay.events.contains(.withdraw))
        #expect(!overlay.snapshots.isEmpty)
        #expect(overlay.snapshots.allSatisfy(Self.speakSnapshots.contains),
                "only the speak reply reached the overlay")
        #expect(overlay.delivered == [["Sort by start.", "Then merge overlaps."]])
    }

    /// Claude without strict tools can double-encode `lines`: the scanner shows nothing early and
    /// the runner's schema re-ask handles the completed call.
    @Test func doubleEncodedLinesShowNothingBeforeTheReask() async {
        let overlay = ProgressRecordingOverlay()
        let malformed = #"{"lines":"[\"a\"]"}"#
        let brain = StreamingBrain(turns: [
            .init(prefixes: [String(malformed.prefix(12)), malformed],
                  outcome: .reply(reply(RawToolCall(id: "m1", name: speakToolName, argumentsJSON: malformed)))),
            .init(prefixes: Self.prefixes, outcome: .reply(speak)),
        ])
        let (driver, _) = makeDriver(brain: brain, overlay: overlay)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.calls.count == 2)
        #expect(!overlay.events.contains(.withdraw))
        #expect(overlay.snapshots.allSatisfy(Self.speakSnapshots.contains))
        #expect(overlay.delivered == [["Sort by start.", "Then merge overlaps."]])
    }

    /// Text that streamed leaves the overlay when the completed call's arguments fail the parser.
    @Test func aParseFailureWithdrawsTheTextItShowed() async throws {
        let overlay = ProgressRecordingOverlay()
        let brain = StreamingBrain(turns: [
            .init(prefixes: [#"{"lines":["Sort by"#],
                  outcome: .reply(reply(RawToolCall(id: "m1", name: speakToolName, argumentsJSON: #"{"lines":["  "]}"#)))),
            .init(prefixes: Self.prefixes, outcome: .reply(speak)),
        ])
        let (driver, _) = makeDriver(brain: brain, overlay: overlay)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.calls.count == 2)
        let events = overlay.events
        let withdraw = try #require(events.firstIndex(of: .withdraw))
        #expect(events[..<withdraw].contains { if case .progress(let snapshot) = $0 { snapshot.openLine == "Sort by" } else { false } },
                "the withdrawn text had been on screen")
        #expect(events[(withdraw + 1)...].allSatisfy { $0 != .withdraw })
        #expect(overlay.delivered == [["Sort by start.", "Then merge overlaps."]])
    }

    @Test func aCallAPressMayNotMakeShowsNothing() async {
        let overlay = ProgressRecordingOverlay()
        let brain = StreamingBrain(turns: [
            .init(call: staySilentTool.name, prefixes: ["{", "{}"],
                  outcome: .reply(reply(RawToolCall(id: "q1", name: staySilentTool.name, argumentsJSON: "{}")))),
            .init(prefixes: Self.prefixes, outcome: .reply(speak)),
        ])
        let (driver, _) = makeDriver(brain: brain, overlay: overlay)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(!overlay.events.contains(.withdraw))
        #expect(overlay.snapshots.allSatisfy(Self.speakSnapshots.contains))
        #expect(overlay.delivered == [["Sort by start.", "Then merge overlaps."]])
    }

    @Test func cancellationMidStreamWithdrawsTheLiveReply() async throws {
        let overlay = ProgressRecordingOverlay()
        let brain = StreamingBrain(turns: [.init(prefixes: [#"{"lines":["Sort by"#], outcome: .hang)])
        let (driver, _) = makeDriver(brain: brain, overlay: overlay)

        let attempt = Task { await driver.handleTrigger(.manualHint) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while overlay.snapshots.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(overlay.snapshots.last?.openLine == "Sort by", "the live reply was on screen")
        attempt.cancel()

        #expect(await attempt.value == .cancelled)
        #expect(overlay.events.last == .withdraw)
        #expect(overlay.delivered.isEmpty)
    }
}
