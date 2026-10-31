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
        let replacement = AsyncGate()
        let brain = ReplacementBrain { index, _ in
            if index == 0 { await pause.wait(); return replacementReply("superseded") }
            await replacement.enter()
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
        #expect(await waitFor { await brain.calls.count == 2 }, "replacement starts before old cleanup finishes")
        #expect(driver.handledTranscriptCount == 0)
        await replacement.release()
        #expect(await waitFor { overlay.rendered == ["replacement"] && driver.handledTranscriptCount == 2 })
        #expect(driver.handledTranscriptCount == 2)
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

    @Test @MainActor func rapidDifferentPressesReplaceAutomaticWorkWithOnlyTheLatestIntent() async {
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
        let operations = [TriggerReason.manualHint, .manualExplanation, .manualCode, .manualCode]
            .map { driver.admitTrigger($0) }
        for operation in operations { #expect(await operation() == .busy) }
        await pause.cancelled.enter()
        #expect(await waitFor { overlay.rendered == ["code"] })
        await pause.cleanup.release()
        #expect(await running.value == .spoke)
        let calls = await brain.calls
        #expect(calls.count == 2)
        #expect(calls[1].compactMap(\.text).joined().contains("Show code"))
        #expect(screen.captureCount == 1)
        #expect(overlay.rendered == ["code"])
    }

    @Test func admissionPreservesPressOrderAndTimeBeforeExecutionStarts() async {
        let clock = ManualClock(now: 100)
        let brain = ReplacementBrain { _, _ in replacementReply("latest") }
        let screen = FakeScreen()
        let driver = driver(brain: brain, screen: screen, clock: clock)
        driver.setMode(.manual)
        clock.advance(by: 1)
        let first = driver.admitTrigger(.manualHint)
        clock.advance(by: 1)
        let second = driver.admitTrigger(.manualExplanation)
        clock.advance(by: 1)
        let latest = driver.admitTrigger(.manualCode)
        clock.advance(by: 10)
        driver.updateTranscriptionWork(.pending(since: 5), for: .them)

        #expect(await latest() == .busy)
        #expect(await second() == .busy)
        #expect(await first() == .spoke, "speech that began after the press must not delay execution")
        #expect(await brain.calls.count == 1)
        #expect(await brain.calls[0].compactMap(\.text).joined().contains("Show code"))
        #expect(screen.captureCount == 1)
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

    private func waitFor(_ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
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

    @Test(arguments: [CoachingMode.automatic, .manual])
    func streamingFinishesBeforeTheLatestQueuedShortcutAndCommitsItsContext(mode: CoachingMode) async {
        let finishStream = AsyncGate()
        let overlay = await ReplacementOverlay()
        let brain = ReplacementBrain { index, progress in
            if index == 1 {
                _ = progress?(.init(index: 0, name: "speak", arguments: #"{"hint":"streamed tip","detail":"more"#))
                await finishStream.enter()
                #expect(!Task.isCancelled)
                return replacementReply("streamed tip")
            }
            return replacementReply(index == 0 ? "completed tip" : "explanation")
        }
        let transcript = RollingTranscript()
        let screen = FakeScreen()
        let driver = driver(brain: brain, transcript: transcript, screen: screen, overlay: overlay)
        driver.setMode(mode)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        transcript.append(.init(speaker: .them, text: "Explain the invariant.", at: 1))
        let running = Task { await driver.handleTrigger(.manualHint) }
        await overlay.painted.enter()
        for reason: TriggerReason in [.manualHint, .manualCode, .manualExplanation, .manualExplanation] {
            #expect(await driver.handleTrigger(reason) == .busy)
        }
        #expect(await brain.calls.count == 2)
        #expect(await MainActor.run { overlay.current?.hint } == "streamed tip")
        #expect(driver.handledTranscriptCount == 0)
        await finishStream.release()
        #expect(await running.value == .spoke)
        #expect(await MainActor.run { overlay.rendered } == ["completed tip", "streamed tip", "explanation"])
        #expect(screen.captureCount == 3)
        #expect(driver.handledTranscriptCount == 1)
        let calls = await brain.calls
        #expect(calls.count == 3)
        #expect(calls.last!.compactMap(\.text).joined().contains("Explain more"))
        #expect(calls.last!.flatMap { $0.toolCalls ?? [] }.contains { $0.argumentsJSON.contains("streamed tip") })
    }

    @Test func stopWithdrawsPartialOutputAndIgnoresLateDeltas() async {
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
        running.cancel()
        await pause.cancelled.enter()
        await overlay.withdrawn.enter()
        #expect(await MainActor.run { overlay.rendered } == ["completed tip"])
        #expect(driver.handledTranscriptCount == 0)
        await pause.cleanup.release()
        #expect(await running.value == .cancelled)
        await brain.emitLateProgress()
        #expect(await MainActor.run { overlay.rendered } == ["completed tip"])
        #expect(await MainActor.run { overlay.current } == nil)
        #expect(driver.handledTranscriptCount == 0)
        let calls = await brain.calls
        #expect(calls.count == 2)
        #expect(calls.last!.flatMap { $0.toolCalls ?? [] }.contains { $0.argumentsJSON.contains("completed tip") })
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
        #expect(await waitFor { overlay.rendered == ["replacement"] })
        await documents.pause.cleanup.release()
        #expect(await running.value == .spoke)
        #expect(await brain.calls.count == 2)
        #expect(overlay.rendered == ["replacement"])
    }

    @Test @MainActor func stopCancelsTheActiveAttemptAndDropsTheReplacement() async {
        let pause = ReplacementPause()
        let brain = ReplacementBrain { _, _ in await pause.wait(); return replacementReply("late") }
        let overlay = FakeOverlay()
        let driver = driver(brain: brain, overlay: overlay)
        let running = Task { await driver.handleTrigger(.manualHint) }
        await pause.entered.waitUntilEntered()
        let pending = driver.admitTrigger(.manualCode)
        running.cancel()
        #expect(await pending() == .busy)
        await pause.cancelled.enter()
        await pause.cleanup.release()
        #expect(await running.value == .cancelled)
        #expect(await brain.calls.count == 1)
        #expect(overlay.rendered.isEmpty)
    }

    @Test @MainActor func aReplacementBeforeTheFirstPaintRejectsBufferedText() async {
        let overlay = ReplacementOverlay()
        let scope = CoachAttemptScope()
        let relay = ReplyProgressRelay(overlay: overlay, scope: scope)
        relay.beginRequest()
        _ = relay.sink(.init(index: 0, name: "speak", arguments: #"{"hint":"buffered"#))
        #expect(scope.replace())
        _ = await relay.endRequest()
        #expect(overlay.current == nil)
        #expect(overlay.paints == 0)
    }

    @Test @MainActor func whitespaceThatCannotOpenAnOverlayEntryDoesNotProtectTheAttempt() async {
        let overlay = ReplacementOverlay()
        let scope = CoachAttemptScope()
        let relay = ReplyProgressRelay(overlay: overlay, scope: scope)
        relay.beginRequest()
        _ = relay.sink(.init(index: 0, name: "speak", arguments: #"{"hint":" \n\t"#))
        _ = await relay.endRequest()
        #expect(overlay.paints == 0)
        #expect(scope.replace())
    }

    @Test func aProtectedStreamStillAccountsForARealPermanentFailure() async {
        let failStream = AsyncGate()
        let overlay = await ReplacementOverlay()
        let brain = ReplacementBrain { index, progress in
            if index == 0 {
                _ = progress?(.init(index: 0, name: "speak", arguments: #"{"hint":"partial"#))
                await failStream.enter()
                throw ProviderFailure(source: .brain(.openAI), stage: .request, category: .authentication,
                    disposition: .permanent, identity: .init(), message: "rejected")
            }
            return replacementReply("incorrectly retried excluded provider")
        }
        let fallback = ScriptedBrain(script: [replacementReply("fallback")])
        let driver = driver(brain: brain, overlay: overlay, fallback: fallback)
        let running = Task { await driver.handleTrigger(.manualHint) }
        await overlay.painted.enter()
        #expect(await driver.handleTrigger(.manualCode) == .busy)
        await failStream.release()
        #expect(await running.value == .spoke)
        #expect(await brain.calls.count == 1)
        #expect(fallback.calls.count == 1)
        #expect(await MainActor.run { overlay.rendered } == ["fallback"])
    }

    @Test(arguments: RetiringConversationBrain.Hold.allCases)
    private func delayedCreationResponseAndFinishCannotBlockTheReplacement(hold: RetiringConversationBrain.Hold) async {
        let brain = RetiringConversationBrain(hold: hold)
        let overlay = FakeOverlay()
        let driver = driver(brain: brain, overlay: overlay)
        let running = Task { await driver.handleTrigger(.manualHint) }
        await brain.pause.entered.waitUntilEntered()
        let replacement = Task { await driver.handleTrigger(.manualCode) }
        #expect(await waitFor { overlay.rendered.contains("replacement") })
        #expect(await brain.finished.filter { $0 == 0 }.isEmpty,
                "late conversation creation and in-flight responses retain their own cleanup")
        await brain.pause.entered.release()
        await brain.pause.cleanup.release()
        #expect(await running.value == .spoke)
        let replacementOutcome = await replacement.value
        if hold == .finish {
            // Cleanup can start before or after the original loop releases its scheduling slot.
            #expect(replacementOutcome == .spoke || replacementOutcome == .busy)
        } else {
            #expect(replacementOutcome == .busy)
        }
        #expect(await brain.finished.sorted() == [0, 1], "every conversation finishes exactly once")
        #expect(overlay.rendered == (hold == .finish ? ["first", "replacement"] : ["replacement"]))
    }

    @Test func stopForwardsCancellationWhileTheOwnerDrainsConversationFinish() async {
        let brain = RetiringConversationBrain(hold: .finish)
        let driver = driver(brain: brain)
        let owner = ReplacementOwnerProbe()
        let running = Task {
            let outcome = await driver.handleTrigger(.manualHint)
            await owner.finish()
            return outcome
        }
        await brain.pause.entered.waitUntilEntered()
        running.cancel()
        #expect(await waitFor { await brain.pause.cancelled.hasBeenReleased })
        #expect(await owner.finished == false)
        await brain.pause.entered.release()
        await brain.pause.cleanup.release()
        #expect(await running.value == .spoke, "a completed tip stays committed during cleanup")
        #expect(await brain.finished == [0])
    }

    @Test func replacementCapturesAndDeliversWhileOldCaptureCleanupIsBlocked() async {
        let screen = ReplacementCaptureFactory()
        let overlay = FakeOverlay()
        let brain = ScriptedBrain(script: [replacementReply("replacement")])
        let driver = driver(brain: brain, screen: screen, overlay: overlay)
        let owner = ReplacementOwnerProbe()
        let running = Task {
            let outcome = await driver.handleTrigger(.manualHint)
            await owner.finish()
            return outcome
        }
        #expect(await waitFor { screen.started == [0] })
        #expect(await driver.handleTrigger(.manualCode) == .busy)
        #expect(await waitFor { overlay.rendered == ["replacement"] })
        #expect(screen.started == [0, 1])
        #expect(screen.cancelled == [0])
        #expect(await owner.finished == false, "the owning task retains the old helper until cleanup")
        screen.release.signal()
        #expect(await running.value == .spoke)
        #expect(screen.cancelled == [0], "old cancellation never reaches the new capture handle")
    }

    @Test func stopDrainsAllRetiringOperationsAndCancelsTheProtectedStream() async {
        let pauses = [ReplacementPause(), ReplacementPause(), ReplacementPause()]
        let overlay = await ReplacementOverlay()
        let brain = ReplacementBrain { index, progress in
            guard index < pauses.count else { return replacementReply("unexpected queued request") }
            if index == 2 { _ = progress?(.init(index: 0, name: "speak", arguments: #"{"hint":"live"#)) }
            await pauses[index].wait()
            return replacementReply("late")
        }
        let driver = driver(brain: brain, overlay: overlay)
        let owner = ReplacementOwnerProbe()
        let running = Task {
            let outcome = await driver.handleTrigger(.manualHint)
            await owner.finish()
            return outcome
        }
        await pauses[0].entered.waitUntilEntered()
        #expect(await driver.handleTrigger(.manualCode) == .busy)
        #expect(await waitFor { await brain.calls.count == 2 })
        #expect(await driver.handleTrigger(.manualExplanation) == .busy)
        #expect(await waitFor { await brain.calls.count == 3 })
        await overlay.painted.enter()
        #expect(await driver.handleTrigger(.manualHint) == .busy)
        running.cancel()
        for pause in pauses { await pause.cancelled.enter() }
        await overlay.withdrawn.enter()
        await pauses[2].cleanup.release()
        await pauses[1].cleanup.release()
        #expect(await owner.finished == false)
        #expect(await brain.calls.count == 3)
        #expect(await MainActor.run { overlay.rendered.isEmpty })
        await pauses[0].cleanup.release()
        #expect(await running.value == .cancelled)
        #expect(await owner.finished)
        await brain.emitLateProgress()
        #expect(await MainActor.run { overlay.current == nil && overlay.rendered.isEmpty })
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
    private(set) var paints = 0
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
        if progress != nil { paints += 1 }
        Task { if progress != nil { await painted.release() } else { await withdrawn.release() } }
    }
}

private actor ReplacementOwnerProbe {
    private(set) var finished = false
    func finish() { finished = true }
}

private actor RetiringConversationBrain: BrainClient {
    enum Hold: CaseIterable, Sendable { case creation, response, finish }
    let hold: Hold
    let pause = ReplacementPause()
    private var count = 0
    private(set) var finished: [Int] = []
    init(hold: Hold) { self.hold = hold }

    func makeConversation(progress: ToolCallProgressSink?) async throws -> any BrainConversation {
        let index = count
        count += 1
        if index == 0, hold == .creation { await pause.wait() }
        return Conversation(brain: self, index: index)
    }

    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        preconditionFailure("the test uses attempt-owned conversations")
    }

    private func respond(index: Int) async -> BrainResponse {
        if index == 0, hold == .response { await pause.wait() }
        return replacementReply(index == 0 ? "first" : "replacement")
    }

    private func finish(index: Int) async {
        if index == 0, hold == .finish { await pause.wait() }
        finished.append(index)
    }

    private struct Conversation: BrainConversation {
        let brain: RetiringConversationBrain
        let index: Int
        func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
            await brain.respond(index: index)
        }
        func finish() async { await brain.finish(index: index) }
    }
}

/// `@unchecked Sendable`: the lock guards observations; the semaphore holds only the old capture.
private final class ReplacementCaptureFactory: ScreenCapturing, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private var captured: [Int] = []
    private var cancellations: [Int] = []
    var started: [Int] { lock.withLock { captured } }
    var cancelled: [Int] { lock.withLock { cancellations } }

    func makeAttemptCapture() -> any ScreenCapturing {
        lock.withLock {
            defer { count += 1 }
            return Capture(owner: self, index: count)
        }
    }
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
        makeAttemptCapture().capture(selection)
    }
    func cancelCapture() {}

    private struct Capture: ScreenCapturing {
        let owner: ReplacementCaptureFactory
        let index: Int
        func makeAttemptCapture() -> any ScreenCapturing { self }
        func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
            owner.lock.withLock { owner.captured.append(index) }
            if index == 0 { owner.release.wait() }
            return .init(imageBase64: "ZmFrZS1qcGVn")
        }
        func cancelCapture() { owner.lock.withLock { owner.cancellations.append(index) } }
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
