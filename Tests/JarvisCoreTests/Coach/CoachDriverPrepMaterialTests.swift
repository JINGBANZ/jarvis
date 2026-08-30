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
    /// Overrides `results` for a specific query, so a test can distinguish which of several calls
    /// produced a given carried observation. Set before the search is exercised; read-only after.
    var resultsByQuery: [String: [PrepMaterialSearchResult]] = [:]
    init(results: [PrepMaterialSearchResult] = []) { self.results = results }
    func search(query: String) -> [PrepMaterialSearchResult] {
        lock.withLock { _queries.append(query) }
        return resultsByQuery[query] ?? results
    }
}

@Suite(.serialized) struct CoachDriverPrepMaterialTests {
    private func makeDriver(
        brain: BrainClient,
        prepMaterial: (any PrepMaterialSearching)? = nil,
        screen: ScreenCapturing = FakeScreen(),
        clock: Clock = ManualClock(now: 100)
    ) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let target = BrainTarget(
            provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let route = ConfiguredBrainRoute(
            targets: [ConfiguredBrainTarget(target: target, brain: brain)])
        let driver = CoachDriver(
            config: .default, transcript: transcript, route: route,
            screen: screen, overlay: FakeOverlay(), clock: clock,
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

    @Test func systemPromptOmitsPrepMaterialGuidanceWhenNotConfigured() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "s1")],
                  rawToolCalls: [RawToolCall(id: "s1", name: "stay_silent", argumentsJSON: "{}")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, prepMaterial: nil)
        transcript.append(.init(speaker: .me, text: "let me think out loud", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        // Describing a tool the model doesn't have invites exactly the hallucinated call that's a
        // hard attempt failure — the guidance must not appear when the tool isn't offered.
        #expect(!brain.calls[0].contains {
            $0.role == .system && ($0.text ?? "").contains("search_prep_notes")
        })
    }

    @Test func systemPromptIncludesPrepMaterialGuidanceWhenConfigured() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "s1")],
                  rawToolCalls: [RawToolCall(id: "s1", name: "stay_silent", argumentsJSON: "{}")]),
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, prepMaterial: FakePrepMaterialSearch())
        transcript.append(.init(speaker: .me, text: "let me think out loud", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(brain.calls[0].contains {
            $0.role == .system && ($0.text ?? "").contains("search_prep_notes")
        })
    }

    @Test func retryAfterCaptureAndSearchPreservesBothObservations() async {
        let brain = ScriptedThrowBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c1")],
                  rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "rate limiter")],
                  rawToolCalls: [RawToolCall(
                    id: "p1", name: "search_prep_notes",
                    argumentsJSON: #"{"query":"rate limiter"}"#)]),
            nil, // fails this attempt — carries work.observations into a fresh retry
            .init(toolCalls: [.speak(callId: "s1", lines: ["done"])],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                             argumentsJSON: #"{"lines":["done"]}"#)]),
        ])
        let screen = FakeScreen(recognizedText: "visible code")
        let prepMaterial = FakePrepMaterialSearch(results: [
            PrepMaterialSearchResult(sourceDisplayName: "notes.md", text: "token bucket details"),
        ])
        let (driver, transcript) = makeDriver(brain: brain, prepMaterial: prepMaterial, screen: screen)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(brain.calls.count == 4)
        let retryRequest = brain.calls[3]
        #expect(retryRequest.contains { $0.imageBase64JPEG != nil })
        #expect(retryRequest.contains { ($0.text ?? "").contains("visible code") })
        #expect(retryRequest.contains { ($0.text ?? "").contains("token bucket details") })
    }

    @Test func secondSearchAcrossRetriesReplacesTheFirstsStaleResult() async {
        // work carries forward verbatim into a retry after a failure (CoachDriver's
        // `work = failedWork`), so a search that fires again on that retry must replace the first
        // search's now-stale result, not pile on top of it — otherwise a long enough failure chain
        // accumulates every prior query's result in every later request.
        let brain = ScriptedThrowBrain(script: [
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "A")],
                  rawToolCalls: [RawToolCall(id: "p1", name: "search_prep_notes",
                                             argumentsJSON: #"{"query":"A"}"#)]),
            nil, // fails — carries the "A" result forward into a fresh attempt
            .init(toolCalls: [.searchPrepNotes(callId: "p2", query: "B")],
                  rawToolCalls: [RawToolCall(id: "p2", name: "search_prep_notes",
                                             argumentsJSON: #"{"query":"B"}"#)]),
            nil, // fails again — the carried result must now be "B" only, not "A" and "B"
            .init(toolCalls: [.speak(callId: "s1", lines: ["done"])],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                             argumentsJSON: #"{"lines":["done"]}"#)]),
        ])
        let prepMaterial = FakePrepMaterialSearch()
        prepMaterial.resultsByQuery = [
            "A": [PrepMaterialSearchResult(sourceDisplayName: "notes.md", text: "result-from-query-A")],
            "B": [PrepMaterialSearchResult(sourceDisplayName: "notes.md", text: "result-from-query-B")],
        ]
        let (driver, transcript) = makeDriver(brain: brain, prepMaterial: prepMaterial)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(brain.calls.count == 5)
        let finalRetryRequest = brain.calls[4]
        #expect(finalRetryRequest.contains { ($0.text ?? "").contains("result-from-query-B") })
        #expect(!finalRetryRequest.contains { ($0.text ?? "").contains("result-from-query-A") })
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
