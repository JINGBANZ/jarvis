import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachCompactionTests {
    enum FailedSummary: CaseIterable, Sendable {
        case request, missing, malformed, incomplete, notSmaller

        var response: BrainResponse? {
            switch self {
            case .request: nil
            case .missing: .init(toolCalls: [])
            case .malformed: .init(toolCalls: [], outputText: "not a briefing")
            case .incomplete:
                .init(toolCalls: [], incompleteReason: "max_output_tokens", outputText: Self.briefing("short"))
            case .notSmaller:
                .init(toolCalls: [], outputText: Self.briefing(String(repeating: "x", count: 40_000)))
            }
        }

        static func briefing(_ context: String) -> String {
            #"{"context":"\#(context)","decisions":[],"coaching":[],"openQuestions":[],"verification":[]}"#
        }
    }

    private func makeRunner(_ transcript: RollingTranscript) -> CoachAttemptRunner {
        CoachAttemptRunner(config: Config(historyCompactionTokenThreshold: 8000),
            transcript: transcript, screen: FakeScreen(), overlay: FakeOverlay(),
            clock: ManualClock(), sessionStart: 0, coachingAttempts: nil, activity: nil,
            ledger: CoachTranscriptLedger(), capabilities: .default)
    }

    private func append(_ text: String, to runner: CoachAttemptRunner, transcript: RollingTranscript,
                        using summarizer: any BrainClient) async -> [ChatMessage] {
        let brain = ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "quiet-\(transcript.count)")])])
        transcript.append(.init(speaker: .me, text: text, at: Double(transcript.count), endedAt: Double(transcript.count)))
        let work = CoachAttemptRunner.PendingCoachingWork(reason: .turnEnd)
        let target = BrainTarget(provider: .openAI,
                                 modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let execution = await runner.runTestAttempt(work, using: .init(
            plan: .default, routeRevision: 0, routeTopologyRevision: 0, routeIndex: 0,
            target: target, brain: brain, summarizer: summarizer, onSelected: nil, documents: nil))
        guard case .completed = execution.result else {
            Issue.record("expected the synthetic turn to commit")
            return []
        }
        return brain.calls.last ?? []
    }

    private func seed(_ runner: CoachAttemptRunner, transcript: RollingTranscript, using summarizer: any BrainClient) async {
        _ = await append("Older decision: Kafka. " + String(repeating: "a", count: 24_000),
                         to: runner, transcript: transcript, using: summarizer)
        let replay = await append("Recent discussion. " + String(repeating: "b", count: 12_000),
                                  to: runner, transcript: transcript, using: summarizer)
        #expect(replay.contains { $0.text?.contains("Older decision: Kafka.") == true })
    }

    @Test(arguments: FailedSummary.allCases)
    func failedBatchIsNotRepeatedUntilSelectedSourceChanges(_ failure: FailedSummary) async throws {
        let transcript = RollingTranscript()
        let runner = makeRunner(transcript)
        let summarizer = ScriptedThrowBrain(script: [failure.response])
        await seed(runner, transcript: transcript, using: summarizer)
        for _ in 0..<5 {
            await runner.startCompactionIfIdle(using: summarizer)?.value
        }
        #expect(summarizer.calls.count == 1)
        let initialInput = try #require(summarizer.calls.first?.last?.text)

        for index in 0..<3 {
            let messages = await append("Small later update \(index)", to: runner, transcript: transcript, using: summarizer)
            #expect(messages.contains { $0.text?.contains("Older decision: Kafka.") == true })
            await runner.startCompactionIfIdle(using: summarizer)?.value
        }
        #expect(summarizer.calls.count == 1)

        _ = await append(String(repeating: "A different substantial discussion. ", count: 900),
                         to: runner, transcript: transcript, using: summarizer)
        await runner.startCompactionIfIdle(using: summarizer)?.value
        #expect(summarizer.calls.count == 2)
        #expect(summarizer.calls.last?.last?.text != initialInput)
        await runner.cancelBackgroundWork()?.value
    }

    @Test func unrelatedTailScreenRewriteDoesNotRetryTheSameBatch() async {
        let transcript = RollingTranscript()
        let runner = makeRunner(transcript)
        let summarizer = ScriptedBrain(script: [.init(toolCalls: [], outputText: "invalid")])
        await seed(runner, transcript: transcript, using: summarizer)
        await runner.startCompactionIfIdle(using: summarizer)?.value
        for index in 0..<3 {
            _ = await append("\(JarvisPrompts.Coach.screenTextHeader)\ntail screen \(index)",
                             to: runner, transcript: transcript, using: summarizer)
            await runner.startCompactionIfIdle(using: summarizer)?.value
        }
        #expect(summarizer.calls.count == 1)
        await runner.cancelBackgroundWork()?.value
    }

    @Test func rewritingTheSelectedScreenAllowsANewRequest() async throws {
        let transcript = RollingTranscript()
        let runner = makeRunner(transcript)
        let summarizer = ScriptedBrain(script: [.init(toolCalls: [], outputText: "invalid")])
        _ = await append("\(JarvisPrompts.Coach.screenTextHeader)\nold screen "
                         + String(repeating: "x", count: 24_000), to: runner, transcript: transcript, using: summarizer)
        _ = await append(String(repeating: "tail ", count: 8000), to: runner, transcript: transcript, using: summarizer)
        await runner.startCompactionIfIdle(using: summarizer)?.value
        let firstInput = try #require(summarizer.calls.first?.last?.text)
        #expect(firstInput.contains("old screen"))

        _ = await append("\(JarvisPrompts.Coach.screenTextHeader)\nnew screen", to: runner, transcript: transcript, using: summarizer)
        await runner.startCompactionIfIdle(using: summarizer)?.value
        #expect(summarizer.calls.count == 2)
        #expect(summarizer.calls.last?.last?.text?.contains("old screen") == false)
        await runner.cancelBackgroundWork()?.value
    }

    @Test func coalescedTriggersDoNotRepeatARejectedBatch() async {
        let transcript = RollingTranscript()
        let runner = makeRunner(transcript)
        let gate = AsyncGate()
        let summarizer = GatedSummary(gate: gate)
        await seed(runner, transcript: transcript, using: summarizer)
        let task = runner.startCompactionIfIdle(using: summarizer)
        #expect(await waitUntilAsync { await gate.hasEntered })
        for _ in 0..<5 { runner.startCompactionIfIdle(using: summarizer) }
        await gate.release()
        await task?.value
        #expect(await summarizer.callCount == 1)
        await runner.cancelBackgroundWork()?.value
    }

    private actor GatedSummary: BrainClient {
        let gate: AsyncGate
        private(set) var callCount = 0

        init(gate: AsyncGate) { self.gate = gate }

        func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
            callCount += 1
            await gate.enter()
            return .init(toolCalls: [], outputText: "invalid")
        }
    }
}
