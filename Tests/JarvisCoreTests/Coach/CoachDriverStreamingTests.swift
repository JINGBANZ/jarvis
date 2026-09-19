import Foundation
import Testing
@testable import JarvisCore

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

        let events = overlay.events
        #expect(events.first == .withdraw, "the load reply ends its request with a withdrawal and no text")
        #expect(events.dropFirst().allSatisfy { $0 != .withdraw })
        #expect(!overlay.snapshots.isEmpty)
        #expect(overlay.delivered == [["Sort by start.", "Then merge overlaps."]])
    }

    /// Claude without strict tools can double-encode `lines`; the scanner shows nothing and the
    /// runner's re-ask ends the request with a withdrawal.
    @Test func aReplyWhoseArgumentsFailToParseIsWithdrawn() async {
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
        #expect(overlay.events.first == .withdraw)
        #expect(overlay.snapshots.allSatisfy { $0.closedLines.first == "Sort by start." })
        #expect(overlay.delivered == [["Sort by start.", "Then merge overlaps."]])
    }

    @Test func aCallAPressMayNotMakeIsWithdrawn() async {
        let overlay = ProgressRecordingOverlay()
        let brain = StreamingBrain(turns: [
            .init(call: staySilentTool.name, prefixes: ["{", "{}"],
                  outcome: .reply(reply(RawToolCall(id: "q1", name: staySilentTool.name, argumentsJSON: "{}")))),
            .init(prefixes: Self.prefixes, outcome: .reply(speak)),
        ])
        let (driver, _) = makeDriver(brain: brain, overlay: overlay)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(overlay.events.first == .withdraw)
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
