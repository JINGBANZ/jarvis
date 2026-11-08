import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachDisplayReceiptTests {
    @Test @MainActor func receiptUsesAcceptedPaintAndDeliveryBeforeActivityProcessing() async throws {
        let clock = ReceiptClock()
        let overlay = ReceiptOverlay(clock: clock)
        let brain = ReceiptBrain()
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .them, text: "Explain this state.", at: 1, endedAt: 2))
        let target = BrainTarget(provider: .openAI, modelID: "fixture")
        let driver = CoachDriver(config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [.init(target: target, brain: brain)]),
            screen: UnavailableScreen(), overlay: overlay, clock: clock,
            automaticAttemptDelay: { _ in }, activity: ReceiptActivity(clock: clock))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 3)) == .silentByModel)
        let history = await brain.requests[1]
        let call = try #require(history.flatMap { $0.toolCalls ?? [] }.first { $0.id == "visible" })
        #expect(call.name == "speak")
        #expect(history.contains {
            $0.role == .tool && $0.toolCallId == call.id &&
                $0.text == "Shown to user from 00:06; complete at 00:08."
        })
    }
}

// @unchecked Sendable: the clock is read by the runner and changed by the main-actor overlay.
private final class ReceiptClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var time = 100.0
    func now() -> TimeInterval { lock.withLock { time } }
    func set(_ value: TimeInterval) { lock.withLock { time = value } }
}

@MainActor private final class ReceiptOverlay: OverlayRendering {
    let clock: ReceiptClock
    init(clock: ReceiptClock) { self.clock = clock }
    var acceptsDetail: Bool { true }
    nonisolated func render(_ hint: String) {}
    func showReplyProgress(_ progress: BrainReplyProgress?) {
        if progress != nil { clock.set(106) }
    }
    func deliver(_ hint: String, detail: ReplyDetail?) -> ReplyDetail? {
        clock.set(108)
        return detail
    }
}

private struct ReceiptActivity: ActivityEventRecording {
    let clock: ReceiptClock
    func record(_ event: ActivityEvent, at date: Date) {
        if case .tip = event { clock.set(110) }
    }
}

private actor ReceiptBrain: BrainClient {
    var requests: [[ChatMessage]] = []
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        requests.append(messages)
        return .init(toolCalls: [.staySilent(callId: "quiet")])
    }
    func makeConversation(progress: ToolCallProgressSink?) async throws -> any BrainConversation {
        Conversation(brain: self, progress: progress)
    }
    private func respond(messages: [ChatMessage], progress: ToolCallProgressSink?) -> BrainResponse {
        requests.append(messages)
        guard requests.count == 1 else { return .init(toolCalls: [.staySilent(callId: "quiet")]) }
        let arguments = #"{"hint":"Use the state meaning.","detail":null}"#
        _ = progress?(.init(index: 0, name: "speak", arguments: arguments))
        return .init(toolCalls: [.speak(callId: "visible", hint: "Use the state meaning.")],
            rawToolCalls: [.init(id: "visible", name: "speak", argumentsJSON: arguments)])
    }
    private struct Conversation: BrainConversation {
        let brain: ReceiptBrain
        let progress: ToolCallProgressSink?
        func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
            await brain.respond(messages: messages, progress: progress)
        }
        func finish() async {}
    }
}
