import Foundation
import Testing
@testable import JarvisCore

@Suite(.serialized, .timeLimit(.minutes(1))) struct CoachDriverReplacementTests {
    private func driver(
        brain: BrainClient, transcript: RollingTranscript = RollingTranscript(),
        screen: ScreenCapturing = FakeScreen(), overlay: OverlayRendering = FakeOverlay(),
        fallback: BrainClient? = nil, documents: (any DocumentSession)? = nil,
        clock: ManualClock = ManualClock(), grace: Duration = .seconds(60),
        delay: @escaping CoachDriver.AutomaticAttemptDelay = { _ in }
    ) -> CoachDriver {
        var targets = [ConfiguredBrainTarget(
            target: .init(provider: .openAI, modelID: "gpt-5.5"), brain: brain)]
        if let fallback {
            targets.append(.init(target: .init(provider: .claudeSubscription, modelID: "claude-sonnet-5-5"), brain: fallback))
        }
        return CoachDriver(config: .default, transcript: transcript, route: .init(targets: targets),
            screen: screen, overlay: overlay, clock: clock, automaticAttemptDelay: delay,
            manualSettlementGrace: grace,
            capabilities: .compose(disabledTools: [], referencesAdmitted: documents != nil), documents: documents)
    }

    @Test(arguments: [CoachingMode.automatic, .manual],
          [TriggerReason.manualHint, .manualExplanation, .manualCode])
    func everyShortcutReplacesEvenAnIdenticalPress(mode: CoachingMode, reason: TriggerReason) async {
        let pause = ReplacementPause()
        let brain = ReplacementBrain { index, _ in
            if index == 0 { await pause.wait(); return replacementReply("superseded") }
            return replacementReply("replacement")
        }
        let screen = FakeScreen()
        let overlay = FakeOverlay()
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .them, text: "Explain binary search.", at: 0))
        let driver = driver(brain: brain, transcript: transcript, screen: screen, overlay: overlay)
        driver.setMode(mode)
        let running = Task { await driver.handleTrigger(reason) }
        await pause.entered.waitUntilEntered()
        transcript.append(.init(speaker: .them, text: "Include the loop invariant.", at: 1))
        #expect(await driver.handleTrigger(reason) == .busy)
        await pause.cancelled.enter()
        #expect(driver.handledTranscriptCount == 0)
        await pause.cleanup.release()
        #expect(await running.value == .spoke)
        #expect(screen.captureCount == 2)
        #expect(overlay.rendered == ["replacement"])
        #expect(driver.handledTranscriptCount == 2)
        let calls = await brain.calls
        #expect(calls.count == 2)
        #expect(calls[1].compactMap(\.text).joined().contains("Include the loop invariant."))
        #expect(!calls[1].compactMap(\.text).joined().contains("superseded"))
    }

    @Test func rapidDifferentPressesReplaceAutomaticWorkWithOnlyTheLatestIntent() async {
        let pause = ReplacementPause()
        let brain = ReplacementBrain { index, _ in
            if index == 0 { await pause.wait(); return replacementReply("superseded") }
            return replacementReply("code")
        }
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .them, text: "Implement binary search.", at: 0))
        let overlay = FakeOverlay()
        let screen = FakeScreen()
        let driver = driver(brain: brain, transcript: transcript, screen: screen, overlay: overlay)
        let running = Task { await driver.handleTrigger(.turnEnd) }
        await pause.entered.waitUntilEntered()
        for reason: TriggerReason in [.manualHint, .manualExplanation, .manualCode, .manualCode] {
            #expect(await driver.handleTrigger(reason) == .busy)
        }
        await pause.cancelled.enter()
        await pause.cleanup.release()
        #expect(await running.value == .spoke)
        let calls = await brain.calls
        #expect(calls.count == 2)
        #expect(calls[1].compactMap(\.text).joined().contains("Show code"))
        #expect(screen.captureCount == 1)
        #expect(overlay.rendered == ["code"])
    }

    @Test func replacementDuringSettlementUsesTheNewPressBoundary() async throws {
        let clock = ManualClock(now: 100)
        let brain = ReplacementBrain { _, _ in replacementReply("latest") }
        let transcript = RollingTranscript()
        let screen = FakeScreen()
        let driver = driver(brain: brain, transcript: transcript, screen: screen, clock: clock)
        driver.setMode(.manual)
        driver.updateTranscriptionWork(.pending(since: 1), for: .them)
        clock.advance(by: 2)
        let running = Task { await driver.handleTrigger(.manualHint) }
        defer { running.cancel() }
        try await waitForSettlement(driver)
        clock.advance(by: 2)
        #expect(await driver.handleTrigger(.manualExplanation) == .busy)
        driver.updateTranscriptionWork(.pending(since: 3), for: .me)
        transcript.append(.init(speaker: .them, text: "Explain the termination proof.", at: 1))
        driver.updateTranscriptionWork(.settled, for: .them)
        try await waitForSettlement(driver)
        #expect(await brain.calls.isEmpty)
        transcript.append(.init(speaker: .me, text: "Each iteration shrinks the interval.", at: 3))
        driver.updateTranscriptionWork(.settled, for: .me)
        #expect(await running.value == .spoke)
        let calls = await brain.calls
        #expect(calls.count == 1)
        #expect(calls[0].compactMap(\.text).joined().contains("Each iteration shrinks"))
        #expect(calls[0].compactMap(\.text).joined().contains("Explain more"))
        #expect(screen.captureCount == 1)
    }

    private func waitForSettlement(_ driver: CoachDriver) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !driver.isWaitingForTranscription {
            try #require(ContinuousClock.now < deadline, "the request reached transcription settlement")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func replacingARetryDiscardsItsCaptureAndKeepsTheFullFallbackBudget() async {
        let waiting = AsyncGate()
        let brain = ReplacementBrain { _, _ in throw URLError(.timedOut) }
        let fallback = ScriptedBrain(script: [replacementReply("fallback")])
        let screen = FakeScreen()
        let driver = driver(brain: brain, screen: screen, fallback: fallback, delay: { _ in
            await withTaskCancellationHandler {
                await waiting.enter()
            } onCancel: { Task { await waiting.release() } }
        })
        driver.setMode(.manual)
        let running = Task { await driver.handleTrigger(.manualHint) }
        await waiting.waitUntilEntered()
        #expect(await driver.handleTrigger(.manualHint) == .busy)
        #expect(await running.value == .spoke)
        #expect(await brain.calls.count == 4, "one old failure plus the replacement's three attempts")
        #expect(fallback.calls.count == 1)
        #expect(screen.captureCount == 2, "each press captures once; its retries reuse that capture")
    }

    @Test func cancellationDoesNotClassifyALatePermanentErrorOrSpendARetry() async {
        let pause = ReplacementPause()
        let brain = ReplacementBrain { index, _ in
            if index == 0 {
                await pause.wait()
                throw ProviderFailure(source: .brain(.openAI), stage: .request, category: .authentication,
                    disposition: .permanent, identity: .init(), message: "late rejection")
            }
            throw URLError(.timedOut)
        }
        let fallback = ScriptedBrain(script: [replacementReply("fallback")])
        let driver = driver(brain: brain, fallback: fallback)
        let running = Task { await driver.handleTrigger(.manualHint) }
        await pause.entered.waitUntilEntered()
        #expect(await driver.handleTrigger(.manualExplanation) == .busy)
        await pause.cancelled.enter()
        await pause.cleanup.release()
        #expect(await running.value == .spoke)
        #expect(await brain.calls.count == 4)
        #expect(fallback.calls.count == 1)
    }

    @Test func partialOutputIsWithdrawnAndLateDeltasCannotTouchTheReplacement() async {
        let pause = ReplacementPause()
        let overlay = await ReplacementOverlay()
        let brain = ReplacementBrain { index, progress in
            if index == 1 {
                _ = progress?(.init(index: 0, name: "speak", arguments: #"{"hint":"unfinished"#))
                await pause.wait()
                return replacementReply("unfinished")
            }
            return replacementReply(index == 0 ? "completed tip" : "replacement")
        }
        let transcript = RollingTranscript()
        let driver = driver(brain: brain, transcript: transcript, overlay: overlay)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        transcript.append(.init(speaker: .them, text: "Now show the implementation.", at: 1))
        let running = Task { await driver.handleTrigger(.manualHint) }
        await pause.entered.waitUntilEntered()
        await overlay.painted.enter()
        #expect(await driver.handleTrigger(.manualCode) == .busy)
        await pause.cancelled.enter()
        await overlay.withdrawn.enter()
        #expect(await MainActor.run { overlay.rendered } == ["completed tip"])
        #expect(driver.handledTranscriptCount == 0)
        await pause.cleanup.release()
        #expect(await running.value == .spoke)
        await brain.emitLateProgress()
        #expect(await MainActor.run { overlay.rendered } == ["completed tip", "replacement"])
        #expect(await MainActor.run { overlay.current } == nil)
        #expect(driver.handledTranscriptCount == 1)
        let calls = await brain.calls
        #expect(calls.last!.flatMap { $0.toolCalls ?? [] }.contains { $0.argumentsJSON.contains("completed tip") })
        #expect(!calls.last!.flatMap { $0.toolCalls ?? [] }.contains { $0.argumentsJSON.contains("unfinished") })
    }

    @Test func aShortcutCancelsAnInFlightReferenceRead() async {
        let documents = ReplacementDocuments()
        let brain = ReplacementBrain { index, _ in
            if index == 0 { return .init(toolCalls: [.readReference(callId: "r", documentID: documents.id, offset: 0)]) }
            return replacementReply("replacement")
        }
        let overlay = FakeOverlay()
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .them, text: "Read the reference before answering.", at: 0))
        let driver = driver(brain: brain, transcript: transcript, overlay: overlay, documents: documents)
        let running = Task { await driver.handleTrigger(.turnEnd) }
        await documents.pause.entered.waitUntilEntered()
        #expect(await driver.handleTrigger(.manualCode) == .busy)
        await documents.pause.cancelled.enter()
        await documents.pause.cleanup.release()
        #expect(await running.value == .spoke)
        #expect(await brain.calls.count == 2)
        #expect(overlay.rendered == ["replacement"])
    }

    @Test func stopCancelsTheActiveAttemptAndDropsTheReplacement() async {
        let pause = ReplacementPause()
        let brain = ReplacementBrain { _, _ in await pause.wait(); return replacementReply("late") }
        let overlay = FakeOverlay()
        let driver = driver(brain: brain, overlay: overlay)
        let running = Task { await driver.handleTrigger(.manualHint) }
        await pause.entered.waitUntilEntered()
        #expect(await driver.handleTrigger(.manualCode) == .busy)
        running.cancel()
        await pause.cancelled.enter()
        await pause.cleanup.release()
        #expect(await running.value == .cancelled)
        #expect(await brain.calls.count == 1)
        #expect(overlay.rendered.isEmpty)
    }
}

private func replacementReply(_ hint: String) -> BrainResponse {
    .init(toolCalls: [.speak(callId: UUID().uuidString, hint: hint)])
}

private struct ReplacementPause: Sendable {
    let entered = AsyncGate()
    let cancelled = AsyncGate()
    let cleanup = AsyncGate()

    func wait() async {
        await withTaskCancellationHandler {
            await entered.enter()
        } onCancel: {
            Task { await cancelled.release(); await entered.release() }
        }
        await cleanup.enter()
    }
}

private actor ReplacementBrain: BrainClient {
    typealias Reply = @Sendable (Int, ToolCallProgressSink?) async throws -> BrainResponse
    let reply: Reply
    private(set) var calls: [[ChatMessage]] = []
    private var sinks: [ToolCallProgressSink] = []

    init(reply: @escaping Reply) { self.reply = reply }

    func makeConversation(progress: ToolCallProgressSink?) async throws -> any BrainConversation {
        if let progress { sinks.append(progress) }
        return Conversation(brain: self, progress: progress)
    }

    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        try await respond(messages, progress: nil)
    }

    func respond(_ messages: [ChatMessage], progress: ToolCallProgressSink?) async throws -> BrainResponse {
        let index = calls.count
        calls.append(messages)
        return try await reply(index, progress)
    }

    func emitLateProgress() {
        for sink in sinks {
            _ = sink(.init(index: 0, name: "speak", arguments: #"{"hint":"late stale delta"}"#))
        }
    }

    private struct Conversation: BrainConversation {
        let brain: ReplacementBrain
        let progress: ToolCallProgressSink?
        func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
            try await brain.respond(messages, progress: progress)
        }
        func finish() async {}
    }
}

@MainActor private final class ReplacementOverlay: OverlayRendering {
    private(set) var rendered: [String] = []
    private(set) var current: BrainReplyProgress?
    let painted = AsyncGate()
    let withdrawn = AsyncGate()
    nonisolated func render(_ hint: String) {}
    func deliver(_ hint: String, detail: ReplyDetail?) -> ReplyDetail? {
        rendered.append(hint)
        current = nil
        return detail
    }
    func showReplyProgress(_ progress: BrainReplyProgress?) {
        current = progress
        Task { if progress != nil { await painted.release() } else { await withdrawn.release() } }
    }
}

private final class ReplacementDocuments: DocumentSession {
    let id = UUID()
    let sessionID = UUID()
    let pause = ReplacementPause()
    func list(query: String?, cursor: Int?) async throws -> ReferenceListResult { throw CancellationError() }
    func search(query: String, documentIDs: [UUID]?) async throws -> ReferenceSearchResult { throw CancellationError() }
    func read(documentID: UUID, offset: Int, revisionID: String?) async throws -> ReferenceReadResult {
        await pause.wait()
        return .init(documentID: id, revisionID: "old", text: "stale evidence", nextOffset: 14,
                     totalScalars: 14, searchReady: true)
    }
}
