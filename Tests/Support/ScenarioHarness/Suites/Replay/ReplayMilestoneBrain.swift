#if JARVIS_LIVE_E2E
import Foundation
import JarvisCore

actor ReplayMilestoneBrain: BrainClient {
    let base: any BrainClient
    private var hook: (@Sendable () async -> Void)?
    init(base: any BrainClient) { self.base = base }
    func arm(_ hook: @escaping @Sendable () async -> Void) { self.hook = hook }
    private func reachMilestone() async {
        let action = hook; hook = nil
        await action?()
    }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        await reachMilestone()
        return try await base.respond(messages: messages, tools: tools, toolChoice: toolChoice)
    }
    func makeConversation(progress: ToolCallProgressSink?) async throws -> any BrainConversation {
        let conversation = try await base.makeConversation(progress: progress)
        return ReplayMilestoneConversation(base: conversation, milestone: { await self.reachMilestone() })
    }
}

private struct ReplayMilestoneConversation: BrainConversation {
    let base: any BrainConversation
    let milestone: @Sendable () async -> Void
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        await milestone()
        return try await base.respond(messages: messages, tools: tools, toolChoice: toolChoice)
    }
    func finish() async { await base.finish() }
}

#endif
