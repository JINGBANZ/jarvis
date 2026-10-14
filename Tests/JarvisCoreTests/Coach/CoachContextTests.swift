import Testing
@testable import JarvisCore

@Suite struct CoachContextTests {
    @Test func anAttemptKeepsItsOpeningInstructionsToolsAndHistoryFrozen() {
        let capabilities = CoachCapabilities.compose(disabledTools: [], prepSourcesConfigured: true)
        let context = CoachContext(capabilities: capabilities)
        context.history.commit([.user("completed first turn")])
        let attempt = context.beginAttempt(prepCatalog: [])
        let turn = [ChatMessage.user("current turn")]
        let opening = attempt.messages(for: turn)

        context.history.commit([.user("completed concurrent turn")])

        #expect(sameMessages(attempt.messages(for: turn), opening))
        #expect(sameMessages(opening, [.system(context.instructions), .user("completed first turn"), .user("current turn")]))
        let next = context.beginAttempt(prepCatalog: [])
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
        let attempt = context.beginAttempt(prepCatalog: [])
        let opening = attempt.messages(for: [.user("current turn")])
        let prefix = try #require(context.history.compactionPrefix())
        #expect(context.history.compact(prefixCount: prefix.count, summary: "Ledger ownership summary.", revision: prefix.revision))
        let compacted = context.history.snapshotWithRevision()
        let next = context.beginAttempt(prepCatalog: [])
        let resetBase = next.messages(for: [])
        #expect(!context.history.compact(prefixCount: prefix.count, summary: "Obsolete concurrent summary.", revision: prefix.revision))
        let retained = context.history.snapshotWithRevision()
        #expect(sameMessages(retained.messages, compacted.messages))
        #expect(retained.revision == compacted.revision)
        #expect(retained.rewriteReason == compacted.rewriteReason)
        let afterRejection = context.beginAttempt(prepCatalog: [])
        #expect(afterRejection.contextRevision == next.contextRevision)
        #expect(afterRejection.rewriteReason == next.rewriteReason)
        #expect(sameMessages(afterRejection.messages(for: []), resetBase))

        #expect(sameMessages(attempt.messages(for: [.user("current turn")]), opening))
        #expect(next.contextRevision > attempt.contextRevision)
        #expect(next.rewriteReason == .compaction)
        #expect(next.messages(for: []).contains { $0.text == JarvisPrompts.Coach.condensedHistory("Ledger ownership summary.") })
        context.history.commit([.user("next completed turn")])
        let following = context.beginAttempt(prepCatalog: [])
        #expect(following.contextRevision == next.contextRevision)
        #expect(sameMessages(Array(following.messages(for: []).prefix(resetBase.count)), resetBase))
    }

    @Test func replacingScreenEvidenceDeclaresARetirementThenAllowsAppendReuse() {
        let context = CoachContext(capabilities: .default)
        context.history.commit([.user("\(JarvisPrompts.Coach.screenTextHeader)\nold code")])
        let before = context.beginAttempt(prepCatalog: [])
        context.history.commit([.userImage("QUJD"), .user("\(JarvisPrompts.Coach.screenTextHeader)\nnew code")])
        let reset = context.beginAttempt(prepCatalog: [])
        #expect(reset.contextRevision > before.contextRevision)
        #expect(reset.rewriteReason == .screenRetirement)
        #expect(!reset.messages(for: []).contains { $0.imageBase64JPEG != nil || $0.text?.contains("old code") == true })
        let resetBase = reset.messages(for: [])
        context.history.commit([.user("next completed turn")])
        let following = context.beginAttempt(prepCatalog: [])
        #expect(following.contextRevision == reset.contextRevision)
        #expect(sameMessages(Array(following.messages(for: []).prefix(resetBase.count)), resetBase))
    }

    @Test func onlyAChangedEnabledPrepCatalogReplacesTheLeadingCatalog() {
        let capabilities = CoachCapabilities.compose(disabledTools: [], prepSourcesConfigured: true)
        let context = CoachContext(capabilities: capabilities)
        context.history.commit([.user("completed conversation")])
        let first = [PrepMaterialDocumentReference(documentID: "ledger", sourceDisplayName: "Ledger.md")]
        let attempt = context.beginAttempt(prepCatalog: first)
        let unchanged = context.beginAttempt(prepCatalog: first)
        #expect(unchanged.contextRevision == attempt.contextRevision)
        #expect(sameMessages(unchanged.messages(for: []), attempt.messages(for: [])))
        let renamed = [PrepMaterialDocumentReference(documentID: "ledger", sourceDisplayName: "Ledger-v2.md")]
        let changed = context.beginAttempt(prepCatalog: renamed)
        #expect(changed.contextRevision > attempt.contextRevision)
        #expect(changed.rewriteReason == .prepCatalogUpdate)
        #expect(changed.messages(for: [])[0].role == .system)
        #expect(changed.messages(for: [])[0].text == context.instructions)
        #expect(changed.messages(for: [])[1].text == JarvisPrompts.Coach.prepDocumentCatalog(renamed))
        #expect(changed.messages(for: []).last?.role == .user)
        #expect(changed.messages(for: []).last?.text == "completed conversation")
        #expect(attempt.messages(for: [])[1].text == JarvisPrompts.Coach.prepDocumentCatalog(first))

        let noPrep = CoachContext(capabilities: .default)
        let unavailable = noPrep.beginAttempt(prepCatalog: first)
        let unavailableChanged = noPrep.beginAttempt(prepCatalog: renamed)
        #expect(unavailableChanged.contextRevision == unavailable.contextRevision)
        #expect(sameMessages(unavailableChanged.messages(for: []), unavailable.messages(for: [])))
    }

    @Test func theFinalResponseNudgeDoesNotChangeTheAttemptBase() {
        let context = CoachContext(capabilities: .default)
        let attempt = context.beginAttempt(prepCatalog: [])
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
