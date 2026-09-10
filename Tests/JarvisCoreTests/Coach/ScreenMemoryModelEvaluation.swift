import Foundation
import Testing
import JarvisBrainProviders
@testable import JarvisCore

/// Opt-in, synthetic evidence only. Uses the production CLI adapter/prompt/tool schemas, never a
/// live screen, microphone, or user session. Assertions check the response's semantic essentials;
/// print full replies for human assessment of qualifiers and unintended accusations.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["JARVIS_SCREEN_MEMORY_EVAL"] == "1"))
struct ScreenMemoryModelEvaluation {
    @Test func retainedEvidenceInformsCoaching() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["JARVIS_EVAL_CLAUDE"])
        let prompt = JarvisPrompts.Coach.system(prepMaterial: false, formatAddendum: "", explanationsEnabled: false)
        let client = CLIBrainClient(
            provider: .claudeCode, executable: URL(fileURLWithPath: executable),
            model: BrainModelCatalog.defaultModel(for: .claudeCode).id,
            workDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeout: 90, systemPrompt: prompt, tools: coachTools, toolChoice: .required,
            prewarm: false)
        defer { client.terminate() }

        struct Scenario {
            let name: String
            let earlier: [String]
            let current: String
            let request: String
        }
        let scenarios = [
            Scenario(name: "split-question", earlier: [
                "Problem: Pair Sum. Return the INDICES of the two elements, not their values. Do not reuse an element."
            ], current: "Example: nums = [2, 7, 11, 15], target = 9", request:
                "Summarize what the answer should contain for this example."),
            Scenario(name: "hidden-implementation", earlier: [
                "def solve(nums):\n    if not nums:\n        return []\n    seen = {}"
            ], current: "    for i, value in enumerate(nums):\n        seen[value] = i", request:
                "Have you already seen an empty-input guard and seen initialization in this function?"),
            Scenario(name: "earlier-bug", earlier: [
                "def count_matches(nums, target):\n    count = 1"
            ], current: "    for value in nums:\n        if value == target:\n            count += 1\n    return count\nTest: nums=[4], target=9. Expected 0, got 1.", request:
                "What could explain this result? Check the code you saw above too."),
            Scenario(name: "fixed-code", earlier: [
                "file: solution.py\ndef count_matches(nums, target):\n    count = 1"
            ], current: "file: solution.py\ndef count_matches(nums, target):\n    count = 0\n    for value in nums:\n        if value == target:\n            count += 1\n    return count", request:
                "I changed the initialization. Is the earlier off-by-one issue still visible?"),
            Scenario(name: "new-question", earlier: [
                "Question A: Find indices of two numbers that sum to target."
            ], current: "Question B: Given a binary tree, return its maximum depth.", request:
                "We finished Pair Sum. This is a completely new question. Explain what it asks."),
        ]
        for scenario in scenarios {
            var memory = ScreenObservationMemory()
            for (index, text) in scenario.earlier.enumerated() {
                memory.record(text: text, sourceID: "window:1", elapsedSeconds: Double(index))
            }
            var messages: [ChatMessage] = [.system(prompt)]
            if let context = memory.contextMessage() { messages.append(context) }
            messages.append(.user("Screen observation ID: 2\n" + JarvisPrompts.Coach.recognizedText(scenario.current)))
            messages.append(.user("New since last turn:\n[00:30] me: " + scenario.request))
            let response = try await client.respond(messages: messages, tools: coachTools, toolChoice: .force("speak"))
            guard case .speak(_, let lines, _, _, _)? = response.toolCalls.first else {
                Issue.record("Expected a reply for \(scenario.name)"); continue
            }
            let reply = lines.joined(separator: " ").lowercased()
            print("SCREEN_MEMORY_EVAL \(scenario.name): \(response.rawToolCalls.map(\.argumentsJSON))")
            switch scenario.name {
            case "split-question":
                #expect(reply.contains("indices") || reply.contains("index"))
                #expect(reply.contains("0") && reply.contains("1"))
            case "hidden-implementation":
                #expect(reply.contains("yes") || reply.contains("already") || reply.contains("saw"))
                #expect(reply.contains("seen") && (reply.contains("guard") || reply.contains("empty") || reply.contains("if not nums")))
            case "earlier-bug":
                #expect(reply.contains("1") && reply.contains("0"))
                #expect(reply.contains("if ") || reply.contains("may ") || reply.contains("might ") || reply.contains("could "))
            case "fixed-code":
                #expect(reply.contains("0"))
                #expect(reply.contains("fixed") || reply.contains("correct") || reply.contains("no "))
                let update = response.rawToolCalls.first.flatMap { ScreenMemoryUpdate.parse($0.argumentsJSON) }
                #expect(update?.obsoleteObservationIDs.contains(1) == true)
            case "new-question":
                #expect(reply.contains("depth") || reply.contains("path"))
                let update = response.rawToolCalls.first.flatMap { ScreenMemoryUpdate.parse($0.argumentsJSON) }
                #expect(update?.newQuestion == true)
            default: break
            }
        }
    }
}
