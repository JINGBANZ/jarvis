import Foundation
import Testing
@testable import JarvisCore

/// A scripted `PrepMaterialSearching` port that records every query it was asked, so a test can
/// assert the model's tool-call argument reached the port unchanged.
///
/// `@unchecked Sendable` is safe because the only mutable property (`_queries`) is accessed only
/// under `lock` — the same justification `ScriptedBrain` in `CoachDriverPipelineTests.swift` gives
/// for its identical pattern.
final class FakePrepMaterialSearch: PrepMaterialSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var _queries: [String] = []
    var queries: [String] { lock.withLock { _queries } }
    let results: [PrepMaterialSearchResult]
    init(results: [PrepMaterialSearchResult] = []) { self.results = results }
    func search(query: String) -> [PrepMaterialSearchResult] {
        lock.withLock { _queries.append(query) }
        return results
    }
}

@Suite(.serialized) struct CoachDriverPrepMaterialTests {
    private func makeDriver(
        brain: BrainClient,
        prepMaterial: (any PrepMaterialSearching)? = nil,
        clock: Clock = ManualClock(now: 100)
    ) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let target = BrainTarget(
            provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let route = ConfiguredBrainRoute(
            targets: [ConfiguredBrainTarget(target: target, brain: brain)])
        let driver = CoachDriver(
            config: .default, transcript: transcript, route: route,
            screen: FakeScreen(), overlay: FakeOverlay(), clock: clock,
            automaticAttemptDelay: { _ in },
            prepMaterial: prepMaterial)
        return (driver, transcript)
    }

    @Test func toolAbsentWhenNoPrepMaterialConfigured() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "s1")],
                  rawToolCalls: [RawToolCall(id: "s1", name: "stay_silent", argumentsJSON: "{}")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, prepMaterial: nil)
        transcript.append(.init(speaker: .me, text: "let me think out loud", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(!brain.offeredTools[0].map(\.name).contains("search_prep_notes"))
    }

    @Test func toolOfferedWhenPrepMaterialConfigured() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "s1")],
                  rawToolCalls: [RawToolCall(id: "s1", name: "stay_silent", argumentsJSON: "{}")]),
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, prepMaterial: FakePrepMaterialSearch())
        transcript.append(.init(speaker: .me, text: "let me think out loud", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(brain.offeredTools[0].map(\.name).contains("search_prep_notes"))
    }

    @Test func searchThenSpeakPipelinePassesTheQueryAndResultThrough() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "rate limiter")],
                  rawToolCalls: [RawToolCall(
                    id: "p1", name: "search_prep_notes",
                    argumentsJSON: #"{"query":"rate limiter"}"#)]),
            .init(toolCalls: [.speak(callId: "s1", lines: ["Use a token bucket."])],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                             argumentsJSON: #"{"lines":["Use a token bucket."]}"#)]),
        ])
        let prepMaterial = FakePrepMaterialSearch(results: [
            PrepMaterialSearchResult(sourceDisplayName: "system-design.md", text: "token bucket notes"),
        ])
        let (driver, transcript) = makeDriver(brain: brain, prepMaterial: prepMaterial)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(prepMaterial.queries == ["rate limiter"])
        #expect(brain.calls.count == 2)
        #expect(brain.calls[1].contains {
            $0.role == .tool && $0.toolCallId == "p1"
                && $0.text?.contains("token bucket notes") == true
                && $0.text?.contains("system-design.md") == true
        })
        #expect(brain.requestContexts.compactMap { $0 }.map(\.phase) == [
            .initial, .searchPrepNotesContinuation,
        ])
    }

    @Test func searchPrepNotesWithoutConfiguredMaterialFailsRatherThanSilentlyEmpty() async {
        // Simulates a non-schema-enforced CLI provider emitting the call even though it was never
        // offered (prepMaterial nil means the tool isn't in the request's tool set at all).
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "rate limiter")],
                  rawToolCalls: [RawToolCall(
                    id: "p1", name: "search_prep_notes",
                    argumentsJSON: #"{"query":"rate limiter"}"#)]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, prepMaterial: nil)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        let outcome = await driver.handleTrigger(.turnEnd)

        // A temporary failure correctly triggers automatic retry (same as any other malformed
        // response) — the scripted brain just keeps replaying the same call, so what matters here
        // is that it's treated as a failure at all, never as a silent empty-result success.
        #expect(outcome == .brainError)
    }

    @Test func noMatchesRendersAnExplicitNoResultsMessage() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "quantum computing")],
                  rawToolCalls: [RawToolCall(
                    id: "p1", name: "search_prep_notes",
                    argumentsJSON: #"{"query":"quantum computing"}"#)]),
            .init(toolCalls: [.staySilent(callId: "s1")],
                  rawToolCalls: [RawToolCall(id: "s1", name: "stay_silent", argumentsJSON: "{}")]),
        ])
        let prepMaterial = FakePrepMaterialSearch(results: [])
        let (driver, transcript) = makeDriver(brain: brain, prepMaterial: prepMaterial)
        transcript.append(.init(speaker: .them, text: "Tell me about quantum computing", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(brain.calls[1].contains {
            $0.role == .tool && $0.text == JarvisPrompts.Coach.prepNotesNoResults
        })
    }
}
