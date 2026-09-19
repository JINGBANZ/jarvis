import Foundation
import Testing
@testable import JarvisCore

@Suite struct SessionMemoryEvaluationBridgeTests {
    private struct Request: Decodable {
        let history: [Record]
        let output: String?
    }

    private struct Record: Codable {
        let role: String
        let text: String?
        let toolCallID: String?
        let calls: [Call]?

        struct Call: Codable {
            let id: String
            let name: String
            let arguments: String
        }

        func message() throws -> ChatMessage {
            let role = try #require(ChatMessage.Role(rawValue: role))
            return ChatMessage(role: role, text: text, toolCallId: toolCallID,
                toolCalls: calls?.map { .init(id: $0.id, name: $0.name, argumentsJSON: $0.arguments) })
        }
    }

    @Test func exchange() throws {
        guard let directory = ProcessInfo.processInfo.environment["JARVIS_MEMORY_EVAL_BRIDGE"] else { return }
        let folder = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath()
        try #require(folder.path.hasPrefix(workspace.appendingPathComponent(".jarvis").path + "/"))
        let request = try JSONDecoder().decode(Request.self,
            from: Data(contentsOf: folder.appendingPathComponent("request.json")))
        let history = CoachHistory()
        history.commit(try request.history.map { try $0.message() })
        let before = history.snapshot()
        let prefix = try #require(history.compactionPrefix())
        let beforeTokens = history.estimatedTokens
        let normalized = request.output.flatMap(JarvisPrompts.HistorySummary.validatedSummary)
        if let normalized {
            #expect(history.compact(prefixCount: prefix.count, summary: normalized, revision: prefix.revision))
        }
        var response: [String: Any] = [
            "system": JarvisPrompts.HistorySummary.system,
            "prefix": try JarvisPrompts.HistorySummary.input(prefix.messages),
            "prefixCount": prefix.count,
            "tail": try JarvisPrompts.HistorySummary.input(Array(before.dropFirst(prefix.count))),
            "history": try JarvisPrompts.HistorySummary.input(history.snapshot()),
            "beforeEstimatedTokens": beforeTokens,
            "afterEstimatedTokens": history.estimatedTokens,
            "valid": normalized != nil
        ]
        response["summary"] = normalized
        let destination = folder.appendingPathComponent("response.json")
        try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
