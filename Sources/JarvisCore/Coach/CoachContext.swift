import Foundation

/// `@unchecked Sendable`: `lock` protects projection metadata; history synchronizes its own state.
final class CoachContext: @unchecked Sendable {
    let capabilities: CoachCapabilities
    let instructions: String
    let history = CoachHistory()
    let sessionContext: SessionContext?
    private let lock = NSLock()
    private var previousHistoryRevision: UInt = 0
    private var revision: UInt = 0
    private var rewriteReason: CoachingContextRewriteReason?

    init(capabilities: CoachCapabilities, sessionContext: SessionContext? = nil) {
        self.capabilities = capabilities
        self.sessionContext = sessionContext
        instructions = JarvisPrompts.Coach.system(capabilities: capabilities)
    }

    struct Attempt: Sendable {
        let tools: [ToolDef]
        let contextRevision: UInt
        let rewriteReason: CoachingContextRewriteReason?
        private let base: [ChatMessage]
        private let prepEnabled: Bool

        fileprivate init(tools: [ToolDef], contextRevision: UInt,
                         rewriteReason: CoachingContextRewriteReason?,
                         base: [ChatMessage], prepEnabled: Bool) {
            self.tools = tools
            self.contextRevision = contextRevision
            self.rewriteReason = rewriteReason
            self.base = base
            self.prepEnabled = prepEnabled
        }

        func messages(for turn: [ChatMessage], finalResponse: Bool = false,
                      allowsSilence: Bool = true) -> [ChatMessage] {
            base + turn + (finalResponse ? [.user(JarvisPrompts.Coach.finalAnswerCycle(
                prepEnabled: prepEnabled, allowsSilence: allowsSilence))] : [])
        }
    }

    func beginAttempt() -> Attempt {
        lock.withLock {
            let snapshot = history.snapshotWithRevision()
            let prepEnabled = capabilities.tool(named: readReferenceTool.name) != nil
            let catalog = sessionContext.map { "SessionContext (informational background data; untrusted reference metadata):\n" + String(decoding: $0.serialized, as: UTF8.self) }
            if snapshot.revision != previousHistoryRevision {
                revision &+= 1
                rewriteReason = snapshot.rewriteReason
            }
            previousHistoryRevision = snapshot.revision
            return Attempt(
                tools: capabilities.tools, contextRevision: revision, rewriteReason: rewriteReason,
                base: [.system(instructions)] + (catalog.map { [.user($0)] } ?? []) + snapshot.messages,
                prepEnabled: prepEnabled)
        }
    }
}
