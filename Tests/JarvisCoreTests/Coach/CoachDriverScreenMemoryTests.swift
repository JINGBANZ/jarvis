import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachDriverScreenMemoryTests {
    @Test func scrollingPreservesEarlierRequirementsAndCodeWithoutOldImages() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "first", lines: ["Keep going."])]),
            .init(toolCalls: [.speak(callId: "second", lines: ["Review the loop."])]),
            .init(toolCalls: [.speak(callId: "third", lines: ["Use the constraints above."])]),
        ])
        let screen = SequenceScreen([
            .init(imageBase64: "FIRST", recognizedText: "Return indices, not values.\nlet seen = [Int: Int]()"),
            .init(imageBase64: "SECOND", recognizedText: "for (index, value) in nums.enumerated() {"),
            .init(imageBase64: "THIRD", recognizedText: "return []"),
        ])
        let driver = makeDriver(brain: brain, screen: screen)
        for _ in 0..<3 { #expect(await driver.handleTrigger(.manualHint) == .spoke) }
        let request = brain.calls[2]
        let text = request.compactMap(\.text).joined(separator: "\n")
        #expect(text.contains("Return indices, not values."))
        #expect(text.contains("let seen = [Int: Int]()"))
        #expect(text.contains("for (index, value) in nums.enumerated() {"))
        #expect(request.compactMap(\.imageBase64JPEG) == ["THIRD"])
    }

    @Test func explicitNewQuestionRetainsItsCaptureAfterProviderRecovery() async {
        let reset = BrainResponse(toolCalls: [.speak(callId: "reset", lines: ["New problem."])],
                                  rawToolCalls: [.init(id: "reset", name: "speak", argumentsJSON:
                                    #"{"lines":["New problem."],"screenMemory":{"newQuestion":true,"obsoleteObservationIDs":[]}}"#)])
        let brain = ScriptedThrowBrain(script: [
            .init(toolCalls: [.speak(callId: "old", lines: ["Continue."])]),
            nil, reset,
            .init(toolCalls: [.speak(callId: "last", lines: ["Continue."])]),
        ])
        let screen = SequenceScreen([
            .init(imageBase64: "A", recognizedText: "old problem constraint"),
            .init(imageBase64: "B", recognizedText: "new problem constraint"),
            .init(imageBase64: "C", recognizedText: "new problem example"),
        ])
        let driver = makeDriver(brain: brain, screen: screen)
        for _ in 0..<3 { #expect(await driver.handleTrigger(.manualHint) == .spoke) }
        let text = brain.calls.last!.filter { $0.role != .system }.compactMap(\.text).joined(separator: "\n")
        #expect(!text.contains("old problem constraint"))
        #expect(text.contains("new problem constraint"))
        #expect(text.contains("new problem example"))
    }

    @Test func proactiveCaptureSurvivesSilenceAndLaterCaptureFailure() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "capture")],
                  rawToolCalls: [.init(id: "capture", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.staySilent(callId: "quiet")]),
            .init(toolCalls: [.speak(callId: "hint", lines: ["Use the earlier constraint."])]),
        ])
        let driver = makeDriver(brain: brain, screen: SequenceScreen([
            .init(imageBase64: "A", recognizedText: "Input is already sorted.")
        ]))
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 20)) == .silentByModel)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        let request = brain.calls.last!
        #expect(request.compactMap(\.text).joined().contains("Input is already sorted."))
        #expect(request.allSatisfy { $0.imageBase64JPEG == nil })
        // A capture continuation must not rewrite the prefix the persistent CLI already received.
        #expect(brain.calls[1].prefix(brain.calls[0].count).map(\.text) == brain.calls[0].map(\.text))
    }

    @Test func obsoleteObservationIsRemovedWithoutRemovingOtherQuestionSections() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "a", lines: ["Continue."])]),
            .init(toolCalls: [.staySilent(callId: "b")]),
            .init(toolCalls: [.speak(callId: "fix", lines: ["Fixed."])], rawToolCalls: [
                .init(id: "fix", name: "speak", argumentsJSON:
                    #"{"lines":["Fixed."],"screenMemory":{"newQuestion":false,"obsoleteObservationIDs":[1]}}"#)
            ]),
            .init(toolCalls: [.speak(callId: "d", lines: ["Continue."])]),
        ])
        let driver = makeDriver(brain: brain, screen: SequenceScreen([
            .init(imageBase64: "A", recognizedText: "count = 1"),
            .init(imageBase64: "B", recognizedText: "Count all matching pairs."),
            .init(imageBase64: "C", recognizedText: "count = 0"),
            .init(imageBase64: "D", recognizedText: "return count"),
        ]))
        for _ in 0..<4 { _ = await driver.handleTrigger(.manualHint) }
        let text = brain.calls.last!.filter { $0.role != .system }.compactMap(\.text).joined(separator: "\n")
        #expect(!text.contains("count = 1"))
        #expect(text.contains("count = 0"))
        #expect(text.contains("Count all matching pairs."))
    }

    @Test func incompleteReplyCannotResetMemory() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "first", lines: ["Continue."])]),
            .init(toolCalls: [.speak(callId: "partial", lines: ["New question."])],
                  rawToolCalls: [.init(id: "partial", name: "speak", argumentsJSON:
                    #"{"lines":["New question."],"screenMemory":{"newQuestion":true,"obsoleteObservationIDs":[]}}"#)],
                  incompleteReason: "max_output_tokens"),
            .init(toolCalls: [.speak(callId: "retry", lines: ["Continue."])]),
            .init(toolCalls: [.speak(callId: "last", lines: ["Continue."])]),
        ])
        let driver = makeDriver(brain: brain, screen: SequenceScreen([
            .init(imageBase64: "A", recognizedText: "Earlier required constraint."),
            .init(imageBase64: "B", recognizedText: "Current example."),
            .init(imageBase64: "C", recognizedText: "Current code."),
        ]))
        for _ in 0..<3 { #expect(await driver.handleTrigger(.manualHint) == .spoke) }
        #expect(brain.calls.last!.compactMap(\.text).joined().contains("Earlier required constraint."))
    }

    @Test func freshDriverDoesNotInheritPreviousSessionEvidence() async {
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: ["Continue."])])])
        let first = makeDriver(brain: brain, screen: SequenceScreen([
            .init(imageBase64: "A", recognizedText: "session one private code")
        ]))
        #expect(await first.handleTrigger(.manualHint) == .spoke)
        let second = makeDriver(brain: brain, screen: SequenceScreen([
            .init(imageBase64: "B", recognizedText: "session two question")
        ]))
        #expect(await second.handleTrigger(.manualHint) == .spoke)
        #expect(!brain.calls.last!.compactMap(\.text).joined().contains("session one private code"))
    }

    @Test func screenEvidenceBypassesLossyConversationCompaction() throws {
        var memory = ScreenObservationMemory()
        memory.record(text: "All pairs must use distinct indices.", sourceID: nil, elapsedSeconds: 0)
        let history = CoachHistory()
        history.commit(CoachHistory.omittingScreenText([
            .user(JarvisPrompts.Coach.recognizedText("All pairs must use distinct indices.")),
            .user("Please give a hint."), .user("More conversation.")
        ]))
        let prefix = try #require(history.compactionPrefix())
        #expect(!JarvisPrompts.HistorySummary.input(prefix.messages).contains("distinct indices"))
        #expect(history.compact(prefixCount: prefix.count, summary: "Discussing Pair Sum.", revision: prefix.revision))
        let input = history.snapshot() + [try #require(memory.contextMessage())]
        #expect(input.compactMap(\.text).joined().contains("All pairs must use distinct indices."))
    }

    @Test func terminalSchemasExposeStrictNullableMaintenance() throws {
        for tool in [speakTool, staySilentTool, systemDesignSpeakTool] {
            let schema = try #require(JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8)) as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: Any])
            let maintenance = try #require(properties["screenMemory"] as? [String: Any])
            #expect(maintenance["type"] as? [String] == ["object", "null"])
            #expect(maintenance["additionalProperties"] as? Bool == false)
            #expect(Set(maintenance["required"] as? [String] ?? []) == ["newQuestion", "obsoleteObservationIDs"])
            #expect((schema["required"] as? [String])?.contains("screenMemory") == true)
        }
    }

    private func makeDriver(brain: BrainClient, screen: ScreenCapturing) -> CoachDriver {
        let target = BrainTarget(provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        return CoachDriver(config: .default, transcript: RollingTranscript(),
                           route: ConfiguredBrainRoute(targets: [.init(target: target, brain: brain)]),
                           screen: screen, overlay: FakeOverlay(), clock: ManualClock(now: 100),
                           automaticAttemptDelay: { _ in }, activity: nil)
    }
}

/// The real capture edge is OS-bound. Only this boundary is substituted; the driver and history run normally.
private final class SequenceScreen: ScreenCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var shots: [ScreenSnapshot]
    init(_ shots: [ScreenSnapshot]) { self.shots = shots }
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
        lock.withLock { shots.isEmpty ? nil : shots.removeFirst() }
    }
    func cancelCapture() {}
}
