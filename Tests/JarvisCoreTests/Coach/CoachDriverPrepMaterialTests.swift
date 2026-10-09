import Foundation
import Testing
@testable import JarvisCore

/// @unchecked: `lock` guards `_queries`, and `resultsByQuery` is set before any search runs.
final class FakePrepMaterialSearch: PrepMaterialSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var _queries: [String] = []
    var queries: [String] { lock.withLock { _queries } }
    let results: [PrepMaterialSearchResult]
    var resultsByQuery: [String: [PrepMaterialSearchResult]] = [:]
    init(results: [PrepMaterialSearchResult] = []) { self.results = results }
    func read(documentID: String, offset: Int) -> PrepMaterialPage? { nil }
    func search(query: String) -> [PrepMaterialSearchResult] {
        lock.withLock { _queries.append(query) }
        return resultsByQuery[query] ?? results
    }
}

@Suite(.serialized) struct CoachDriverPrepMaterialTests {
    private func makeDriver(
        brain: BrainClient,
        prepMaterial: (any PrepMaterialSearching)? = nil,
        capabilities: CoachCapabilities? = nil,
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
            capabilities: capabilities ?? .compose(
                disabledTools: [], prepSourcesConfigured: prepMaterial != nil),
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

    @Test func toolCatalogedButNotDeclaredWhenPrepMaterialConfigured() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "s1")],
                  rawToolCalls: [RawToolCall(id: "s1", name: "stay_silent", argumentsJSON: "{}")]),
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, prepMaterial: FakePrepMaterialSearch())
        transcript.append(.init(speaker: .me, text: "let me think out loud", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(!brain.offeredTools[0].map(\.name).contains("search_prep_notes"))
        #expect(brain.offeredTools[0].map(\.name).contains("load_tool"))
        #expect(brain.offeredTools[0].map(\.name).contains("call_tool"))
        #expect(brain.calls[0].contains {
            $0.role == .system && ($0.text ?? "").contains("- search_prep_notes:")
        })
    }

    @Test func searchThenSpeakPipelinePassesTheQueryAndResultThrough() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "rate limiter")],
                  rawToolCalls: [RawToolCall(
                    id: "p1", name: "call_tool",
                    argumentsJSON: #"{"name":"search_prep_notes","arguments":"{\"query\":\"rate limiter\"}"}"#)]),
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
                && $0.text?.hasPrefix(JarvisPrompts.Coach.prepNotesResultHeader) == true
        })
        #expect(brain.requestContexts.compactMap { $0 }.map(\.phase) == [
            .initial, .searchPrepNotesContinuation,
        ])
    }

    @Test func systemPromptOmitsPrepMaterialGuidanceWhenNotConfigured() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "s1")],
                  rawToolCalls: [RawToolCall(id: "s1", name: "stay_silent", argumentsJSON: "{}")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, prepMaterial: nil)
        transcript.append(.init(speaker: .me, text: "let me think out loud", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(!brain.calls[0].contains {
            $0.role == .system
                && (($0.text ?? "").contains("search_prep_notes")
                    || ($0.text ?? "").contains("load_tool"))
        })
    }

    @Test func systemPromptCatalogsPrepNotesSearchWhenConfigured() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "s1")],
                  rawToolCalls: [RawToolCall(id: "s1", name: "stay_silent", argumentsJSON: "{}")]),
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, prepMaterial: FakePrepMaterialSearch())
        transcript.append(.init(speaker: .me, text: "let me think out loud", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        let prompt = brain.calls[0].first { $0.role == .system }?.text ?? ""
        #expect(prompt.contains("# Tools you can load"))
        #expect(prompt.contains("- search_prep_notes:"))
        #expect(!prompt.contains("# Prep material"))
    }

    @Test func retryAfterCaptureAndSearchPreservesBothObservations() async {
        let brain = ScriptedThrowBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c1")],
                  rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "rate limiter")],
                  rawToolCalls: [RawToolCall(
                    id: "p1", name: "call_tool",
                    argumentsJSON: #"{"name":"search_prep_notes","arguments":"{\"query\":\"rate limiter\"}"}"#)]),
            nil,
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
        let brain = ScriptedThrowBrain(script: [
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "A")],
                  rawToolCalls: [RawToolCall(id: "p1", name: "call_tool",
                                             argumentsJSON: #"{"name":"search_prep_notes","arguments":"{\"query\":\"A\"}"}"#)]),
            nil,
            .init(toolCalls: [.searchPrepNotes(callId: "p2", query: "B")],
                  rawToolCalls: [RawToolCall(id: "p2", name: "call_tool",
                                             argumentsJSON: #"{"name":"search_prep_notes","arguments":"{\"query\":\"B\"}"}"#)]),
            nil,
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
                    id: "p1", name: "call_tool",
                    argumentsJSON: #"{"name":"search_prep_notes","arguments":"{\"query\":\"quantum computing\"}"}"#)]),
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
    @Test func readDocumentReturnsOriginalContentToTheBrain() async throws {
        let original = "# Design\n\n## Architecture\n\nPersist an operation before calling the network.\n"
        let index = PrepMaterialIndex(documents: [
            PrepMaterialDocument(sourceDisplayName: "design.md", text: original),
        ])
        let documentID = try #require(index.search(query: "design.md").first?.documentID)
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: [
            "name": "read_prep_note", "arguments": ["document_id": documentID, "offset": 0],
        ]), as: UTF8.self)
        let call = try #require(ToolInvocation.parse(callId: "read", name: "call_tool", argumentsJSON: arguments))
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [call], rawToolCalls: [RawToolCall(
                id: "read", name: "call_tool", argumentsJSON: arguments)]),
            .init(toolCalls: [.speak(callId: "reply", lines: ["Persist before calling."])],
                  rawToolCalls: [RawToolCall(id: "reply", name: "speak",
                                            argumentsJSON: #"{"lines":["Persist before calling."]}"#)]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, prepMaterial: index)
        transcript.append(.init(speaker: .me, text: "Read the whole design document", at: 100))
        _ = await driver.handleTrigger(.turnEnd)
        let result = try #require(brain.calls[1].first { $0.toolCallId == "read" && $0.role == .tool })
        #expect(result.text?.contains(original) == true)
        #expect(result.text?.contains("End of document") == true)
        #expect(brain.requestContexts.compactMap { $0 }.map(\.phase) == [.initial, .readPrepNoteContinuation])
    }

    @Test func readWithoutIndexReportsUnavailableInsteadOfClaimingEmptyFile() async throws {
        let arguments = #"{"name":"read_prep_note","arguments":{"document_id":"missing","offset":0}}"#
        let call = try #require(ToolInvocation.parse(callId: "read", name: "call_tool", argumentsJSON: arguments))
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [call], rawToolCalls: [RawToolCall(
                id: "read", name: "call_tool", argumentsJSON: arguments)]),
            .init(toolCalls: [.staySilent(callId: "s")],
                  rawToolCalls: [RawToolCall(id: "s", name: "stay_silent", argumentsJSON: "{}")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain,
            capabilities: .compose(disabledTools: [], prepSourcesConfigured: true))
        transcript.append(.init(speaker: .me, text: "Read my notes", at: 100))
        _ = await driver.handleTrigger(.turnEnd)
        #expect(brain.calls[1].contains {
            $0.toolCallId == "read" && $0.text == JarvisPrompts.Coach.prepNotesUnavailable
        })
    }

}
