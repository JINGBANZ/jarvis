import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachContextTests {
    @Test func anAttemptKeepsItsOpeningInstructionsToolsAndHistoryFrozen() {
        let capabilities = CoachCapabilities.compose(disabledTools: [], referencesAdmitted: true)
        let context = CoachContext(capabilities: capabilities)
        context.history.commit([.user("completed first turn")])
        let attempt = context.beginAttempt()
        let turn = [ChatMessage.user("current turn")]
        let opening = attempt.messages(for: turn)

        context.history.commit([.user("completed concurrent turn")])

        #expect(sameMessages(attempt.messages(for: turn), opening))
        #expect(sameMessages(opening, [.system(context.instructions), .user("completed first turn"), .user("current turn")]))
        let next = context.beginAttempt()
        #expect(next.tools == attempt.tools)
        #expect(next.tools == capabilities.tools)
        #expect(next.contextRevision == attempt.contextRevision)
        #expect(next.rewriteReason == nil)
        #expect(next.messages(for: []).first?.role == .system)
        #expect(next.messages(for: []).first?.text == context.instructions)
        #expect(next.messages(for: []).last?.role == .user)
        #expect(next.messages(for: []).last?.text == "completed concurrent turn")
    }

    @Test func compactionChangesTheNextAttemptWithoutChangingAnExistingAttempt() throws {
        let context = CoachContext(capabilities: .default)
        let oldText = "Original ledger discussion: " + String(repeating: "preserve checkpoint ownership. ", count: 30)
        context.history.commit([.user(oldText), .user("recent tail")])
        let attempt = context.beginAttempt()
        let opening = attempt.messages(for: [.user("current turn")])
        let prefix = try #require(context.history.compactionPrefix())
        #expect(context.history.compact(prefixCount: prefix.count, summary: "Ledger ownership summary.", revision: prefix.revision))
        let compacted = context.history.snapshotWithRevision()
        let next = context.beginAttempt()
        let resetBase = next.messages(for: [])
        #expect(!context.history.compact(prefixCount: prefix.count, summary: "Obsolete concurrent summary.", revision: prefix.revision))
        let retained = context.history.snapshotWithRevision()
        #expect(sameMessages(retained.messages, compacted.messages))
        #expect(retained.revision == compacted.revision)
        #expect(retained.rewriteReason == compacted.rewriteReason)
        let afterRejection = context.beginAttempt()
        #expect(afterRejection.contextRevision == next.contextRevision)
        #expect(afterRejection.rewriteReason == next.rewriteReason)
        #expect(sameMessages(afterRejection.messages(for: []), resetBase))

        #expect(sameMessages(attempt.messages(for: [.user("current turn")]), opening))
        #expect(next.contextRevision > attempt.contextRevision)
        #expect(next.rewriteReason == .compaction)
        #expect(next.messages(for: []).contains { $0.text == JarvisPrompts.Coach.condensedHistory("Ledger ownership summary.") })
        context.history.commit([.user("next completed turn")])
        let following = context.beginAttempt()
        #expect(following.contextRevision == next.contextRevision)
        #expect(sameMessages(Array(following.messages(for: []).prefix(resetBase.count)), resetBase))
    }

    @Test func replacingScreenEvidenceDeclaresARetirementThenAllowsAppendReuse() {
        let context = CoachContext(capabilities: .default)
        context.history.commit([.user("\(JarvisPrompts.Coach.screenTextHeader)\nold code")])
        let before = context.beginAttempt()
        context.history.commit([.userImage("QUJD"), .user("\(JarvisPrompts.Coach.screenTextHeader)\nnew code")])
        let reset = context.beginAttempt()
        #expect(reset.contextRevision > before.contextRevision)
        #expect(reset.rewriteReason == .screenRetirement)
        #expect(!reset.messages(for: []).contains { $0.imageBase64JPEG != nil || $0.text?.contains("old code") == true })
        let resetBase = reset.messages(for: [])
        context.history.commit([.user("next completed turn")])
        let following = context.beginAttempt()
        #expect(following.contextRevision == reset.contextRevision)
        #expect(sameMessages(Array(following.messages(for: []).prefix(resetBase.count)), resetBase))
    }

    @Test func immutableSessionContextSurvivesCompactionExactlyOnceBeforeHistory() throws {
        let frozen = try SessionContext(documentCatalog: .bounded([.init(documentID: UUID(), name: "Ledger.md", format: "md")]))
        let context = CoachContext(capabilities: .compose(disabledTools: [], referencesAdmitted: true), sessionContext: frozen)
        context.history.commit([.user(String(repeating: "Old reference discussion. ", count: 50)), .user("recent tail")])
        let opening = context.beginAttempt()
        let block = try #require(opening.messages(for: [])[1].text)
        let prefix = try #require(context.history.compactionPrefix())
        #expect(!prefix.messages.compactMap(\.text).joined().contains("documentCatalog"))
        #expect(context.history.compact(prefixCount: prefix.count, summary: "Summarized reference discussion", revision: prefix.revision))
        let next = context.beginAttempt()
        let messages = next.messages(for: [])
        #expect(messages[1].role == .user && messages[1].text == block)
        #expect(messages.filter { $0.text == block }.count == 1)
        #expect(messages[2].text == JarvisPrompts.Coach.condensedHistory("Summarized reference discussion"))
        #expect(next.tools == opening.tools)
        #expect(block.contains(String(decoding: frozen.serialized, as: UTF8.self)))
    }

    @Test func theFinalResponseNudgeDoesNotChangeTheAttemptBase() {
        let context = CoachContext(capabilities: .default)
        let attempt = context.beginAttempt()
        let turn = [ChatMessage.user("current turn")]
        let ordinary = attempt.messages(for: turn)
        let final = attempt.messages(for: turn, finalResponse: true, allowsSilence: false)
        #expect(sameMessages(Array(final.prefix(ordinary.count)), ordinary))
        #expect(final.last?.text == JarvisPrompts.Coach.finalAnswerCycle(prepEnabled: false, allowsSilence: false))
        #expect(sameMessages(attempt.messages(for: turn), ordinary))
        #expect(context.history.snapshot().isEmpty)
    }

    private func sameMessages(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.role == $1.role && $0.text == $1.text && $0.imageBase64JPEG == $1.imageBase64JPEG
                && $0.toolCallId == $1.toolCallId && $0.toolCalls == $1.toolCalls
                && $0.rawItemsJSON == $1.rawItemsJSON
        }
    }
}
