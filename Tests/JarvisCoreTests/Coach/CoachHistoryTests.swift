import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachHistoryTests {
    @Test func commitAppendsInOrder() {
        let h = CoachHistory()
        h.commit([.user("one")])
        h.commit([.user("two")])
        #expect(h.snapshot().compactMap(\.text) == ["one", "two"])
    }

    @Test func imagesBecomeStubsAtCommit() {
        let h = CoachHistory()
        h.commit([.user("a"), .userImage("QUJD")])
        h.commit([.user("b"), .userImage("REVG")])
        let snap = h.snapshot()
        #expect(!snap.contains { $0.imageBase64JPEG != nil })
        #expect(snap.filter { ($0.text ?? "").contains("no longer available") }.count == 2)
        #expect(snap.compactMap(\.text).first == "a")
        // A stub naming capture_screen made the model capture on every quiet turn.
        #expect(!snap.contains { ($0.text ?? "").contains("capture_screen") })
    }

    @Test func newCaptureCollapsesSupersededScreenText() {
        let ocr = { (body: String) in "\(JarvisPrompts.Coach.screenTextHeader)\n\(body)" }
        let h = CoachHistory()
        h.commit([.user("turn 1"),
                  .init(role: .tool, text: "screenshot captured\n\n\(ocr("if (min < sum)"))", toolCallId: "c1")])
        h.commit([.user("turn 2")])
        #expect(h.snapshot().contains { ($0.text ?? "").contains("if (min < sum)") })

        h.commit([.user(ocr("if (sum < min)"))])
        var texts = h.snapshot().compactMap(\.text)
        #expect(texts.contains("screenshot captured\n\n\(JarvisPrompts.Coach.supersededScreenTextStub)"))
        #expect(!texts.joined().contains("if (min < sum)"))
        #expect(texts.contains { $0.contains("if (sum < min)") })

        h.commit([.init(role: .tool, text: "screenshot captured\n\n\(ocr("rewritten"))", toolCallId: "c2")])
        texts = h.snapshot().compactMap(\.text)
        #expect(texts.contains(JarvisPrompts.Coach.supersededScreenTextStub))
        #expect(!texts.joined().contains("if (sum < min)"))
        #expect(texts.contains { $0.contains("rewritten") })
        #expect(h.snapshot().contains { $0.toolCallId == "c1" })
    }

    @Test func multiCaptureTurnKeepsOnlyItsNewestScreenText() {
        let ocr = { (body: String) in "\(JarvisPrompts.Coach.screenTextHeader)\n\(body)" }
        let h = CoachHistory()
        h.commit([.user("turn"),
                  .init(role: .tool, text: "screenshot captured\n\n\(ocr("first look"))", toolCallId: "c1"),
                  .init(role: .tool, text: "screenshot captured\n\n\(ocr("second look"))", toolCallId: "c2")])
        let texts = h.snapshot().compactMap(\.text)
        #expect(!texts.joined().contains("first look"))
        #expect(texts.contains("screenshot captured\n\n\(JarvisPrompts.Coach.supersededScreenTextStub)"))
        #expect(texts.contains { $0.contains("second look") })
        #expect(h.snapshot().contains { $0.toolCallId == "c1" })
    }

    @Test func committedScreenTextKeepsItsCaptureTime() throws {
        let captured = JarvisPrompts.Coach.screenText([
            ScreenTextEvidence(text: "intervals.sort()", source: .onDeviceOCR, coverage: .currentViewport),
            ScreenTextEvidence(text: "Merge Intervals", source: .browserAccessibility,
                               coverage: .activeTabAccessibilityTree),
        ], capturedAt: "01:29")
        #expect(captured.contains("On-device OCR (captured at [01:29]"))
        #expect(captured.contains("Chrome Accessibility (captured at [01:29]"))

        let h = CoachHistory()
        h.commit([.user("turn"),
                  .init(role: .tool, text: "screenshot captured\n\n\(captured)", toolCallId: "c1")])

        let committed = try #require(h.snapshot().first { $0.toolCallId == "c1" }?.text)
        #expect(committed == "screenshot captured\n\n\(captured)")
    }

    @Test func rawPassthroughItemsAreConvertedAtCommit() {
        let h = CoachHistory()
        h.commit([.user("a"),
                  .rawItems([#"{"type":"reasoning","id":"rs_1","encrypted_content":"blob"}"#,
                             #"{"type":"function_call","id":"fc_1","call_id":"c1","name":"capture_screen","arguments":"{}"}"#],
                            calls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")]),
                  .init(role: .tool, text: "screenshot captured", toolCallId: "c1")])
        let snap = h.snapshot()
        #expect(!snap.contains { $0.rawItemsJSON != nil })
        #expect(!snap.contains { ($0.toolCalls?.first?.argumentsJSON ?? "").contains("blob") })
        #expect(snap.compactMap(\.toolCalls).flatMap { $0 }
                == [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")])
        #expect(snap.contains { $0.role == .tool && $0.toolCallId == "c1" })
    }

    /// The items here aren't OpenAI's shape; commit must not need to read them.
    @Test func commitKeepsParsedCallsWithoutReadingRawItems() {
        let h = CoachHistory()
        let call = RawToolCall(id: "call_1_ab12cd34", name: "capture_screen", argumentsJSON: "{}")
        h.commit([.user("a"),
                  .rawItems([#"{"type":"thought","signature":"opaque"}"#,
                             #"{"type":"function_call","id":"call_1_ab12cd34","name":"capture_screen","arguments":{}}"#],
                            calls: [call]),
                  .init(role: .tool, text: "screenshot captured", toolCallId: "call_1_ab12cd34")])
        let snap = h.snapshot()
        #expect(!snap.contains { $0.rawItemsJSON != nil })
        #expect(snap.compactMap(\.toolCalls).flatMap { $0 } == [call])
        #expect(snap.contains { $0.role == .tool && $0.toolCallId == "call_1_ab12cd34" })
    }

    @Test func reasoningOnlyPassthroughIsDroppedWholeAtCommit() {
        let h = CoachHistory()
        h.commit([.user("a"), .rawItems([#"{"type":"reasoning","id":"rs_1"}"#], calls: []), .user("b")])
        #expect(h.snapshot().compactMap(\.text) == ["a", "b"])
        #expect(!h.snapshot().contains { $0.rawItemsJSON != nil || $0.toolCalls != nil })
    }

    @Test func staySilentCallsAndTheirResultsNeverEnterMemory() {
        let h = CoachHistory()
        h.commit([
            .user("a"),
            .assistantToolCalls([
                RawToolCall(id: "q1", name: "stay_silent", argumentsJSON: "{}"),
                RawToolCall(id: "l1", name: "load_skill", argumentsJSON: #"{"name":"coding"}"#),
            ]),
            .init(role: .tool, text: "not on a shortcut press", toolCallId: "q1"),
            .init(role: .tool, text: "Loaded coding.", toolCallId: "l1"),
            .rawItems([#"{"type":"function_call","call_id":"q2","name":"stay_silent","arguments":"{}"}"#],
                      calls: [RawToolCall(id: "q2", name: "stay_silent", argumentsJSON: "{}")]),
            .init(role: .tool, text: "not executed", toolCallId: "q2"),
            .assistantToolCalls([RawToolCall(id: "s1", name: "speak", argumentsJSON: #"{"hint":"Hi."}"#)]),
            .init(role: .tool, text: "shown", toolCallId: "s1"),
        ])

        let snap = h.snapshot()
        #expect(snap.count == 5)
        #expect(snap.first?.text == "a")
        #expect(snap.flatMap { $0.toolCalls ?? [] }.map(\.name) == ["load_skill", "speak"])
        #expect(snap.compactMap(\.toolCallId) == ["l1", "s1"])
    }

    @Test func compactionPrefixBoundsRespectTheTail() {
        let h = CoachHistory()
        #expect(h.compactionPrefix() == nil)
        h.commit([.user("only")])
        #expect(h.compactionPrefix() == nil)
        h.commit([.user(String(repeating: "x", count: 4000)), .user("tail")])
        let prefix = h.compactionPrefix()
        #expect(prefix != nil)
        #expect(prefix!.count < h.snapshot().count)
    }

    @Test func briefingReplacesOlderTurnsAndShrinksHistory() throws {
        let history = CoachHistory()
        history.commit([
            .user("Use Kafka with an inclusive cutoff; tests have not run. "
                  + String(repeating: "Resolved discussion about the old approach. ", count: 200)),
            .user("The old approach is retired."),
            .user("The current question is how to test the boundary.")
        ])
        let beforeTokens = history.estimatedTokens
        let prefix = try #require(history.compactionPrefix())
        let output = "{\"context\":\"Queue review\",\"decisions\":[\"Kafka; inclusive cutoff\"],"
            + "\"coaching\":[],\"openQuestions\":[\"Boundary tests\"],\"verification\":[\"Tests not run. "
            + Array(repeating: "a", count: 260).joined(separator: " ") + "\"]}"
        let summary = try #require(JarvisPrompts.HistorySummary.validatedSummary(output))

        guard case .accepted = history.compact(prefixCount: prefix.count, summary: summary, revision: prefix.revision) else {
            Issue.record("expected the summary to reduce history"); return
        }
        #expect(history.estimatedTokens < beforeTokens)
        let retained = history.snapshot().compactMap(\.text).joined(separator: "\n")
        #expect(!retained.contains("Resolved discussion about the old approach."))
        #expect(retained.contains("Kafka; inclusive cutoff"))
        #expect(retained.contains("Tests not run."))
        #expect(retained.contains("The current question is how to test the boundary."))
    }

    @Test func oversizedBriefingKeepsNewerDecisionsAndVerificationForTheNextSummary() throws {
        let history = CoachHistory()
        history.commit([
            .user("Java version A tests were reported as passing; system design chose Kafka. "
                  + String(repeating: "Resolved discussion. ", count: 1500)),
            .user("Continue the review.")
        ])
        let selected = try #require(history.compactionPrefix())
        let output = #"{"context":"Java coding and system design","decisions":["System design: Kafka"],"coaching":[],"openQuestions":[],"verification":["Java version A: user reported passing tests. \#(String(repeating: "Evidence details. ", count: 200))"]}"#
        let summary = try #require(JarvisPrompts.HistorySummary.validatedSummary(output))
        #expect(CoachHistory.estimatedTextTokens(summary) > 750)
        let update = "System design now uses SQS. Java version B changes the boundary comparison; tests have not been rerun."
        history.commit([.user(update)])
        let before = history.estimatedTokens
        guard case .accepted(let recordedBefore, let after) = history.compact(
            prefixCount: selected.count, summary: summary, revision: selected.revision) else {
            Issue.record("expected the oversized but smaller briefing to be accepted")
            return
        }
        #expect(recordedBefore == before)
        #expect(after == history.estimatedTokens && after < before)
        #expect(history.snapshot().last?.text == update)

        history.commit([.user(String(repeating: "Current question. ", count: 50))])
        let next = try #require(history.compactionPrefix(fraction: 0.99))
        let input = try JarvisPrompts.HistorySummary.input(next.messages)
        #expect(input.contains("System design: Kafka"))
        #expect(input.contains(update))
        let records = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [[String: Any]])
        #expect(records.first?["text"] as? String == JarvisPrompts.Coach.condensedHistory(summary))
        #expect(records.last?["text"] as? String == update)
    }

    @Test func replacementMustShrinkAfterIncludingItsEnvelopeAndRetainedLoads() throws {
        let history = CoachHistory()
        let load = RawToolCall(id: "load", name: "load_skill", argumentsJSON: #"{"name":"coding"}"#)
        history.commit([
            .user("Old fact."),
            .assistantToolCalls([load]),
            .init(role: .tool, text: String(repeating: "Skill guidance. ", count: 200), toolCallId: load.id),
            .user("Recent question.")
        ])
        let before = history.snapshotWithRevision()
        let original = try JarvisPrompts.HistorySummary.input(before.messages)
        #expect(history.compact(prefixCount: 3, summary: "Fact.", revision: before.revision) == .notSmaller)
        let after = history.snapshotWithRevision()
        #expect(try JarvisPrompts.HistorySummary.input(after.messages) == original)
        #expect(after.revision == before.revision)
        #expect(after.rewriteReason == before.rewriteReason)
    }

    @Test func equallySizedBriefingLeavesHistoryUntouched() {
        let history = CoachHistory()
        let original = JarvisPrompts.Coach.condensedHistory("Old fact.")
        history.commit([.user(original), .user("Recent question.")])
        let before = history.snapshotWithRevision()
        #expect(history.compact(prefixCount: 1, summary: "New fact.", revision: before.revision) == .notSmaller)
        #expect(history.snapshot().first?.text == original)
        #expect(history.snapshotWithRevision().revision == before.revision)
    }

    /// Sized so the greedy 60% budget fits the call at index 5 but not its result at index 6.
    private static let callIndex = 5
    private static let resultIndex = 6

    private func historyWithAPairAtTheGreedyBoundary(
        call: RawToolCall, result: String
    ) -> CoachHistory {
        let filler = String(repeating: "x", count: 400)
        let history = CoachHistory()
        history.commit(
            Array(repeating: ChatMessage.user(filler), count: Self.callIndex)
                + [.assistantToolCalls([call]),
                   .init(role: .tool, text: result, toolCallId: call.id)]
                + Array(repeating: ChatMessage.user(filler), count: 3))
        return history
    }

    @Test func theCompactionPrefixNeverSplitsACallFromItsResult() throws {
        let call = RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")
        let h = historyWithAPairAtTheGreedyBoundary(
            call: call, result: String(repeating: "y", count: 400))

        let prefix = try #require(h.compactionPrefix())

        #expect(prefix.count == Self.resultIndex + 1)
        let messages = h.snapshot()
        let calledBefore = Set(messages.prefix(prefix.count).flatMap { $0.toolCalls ?? [] }.map(\.id))
        let answeredAfter = Set(messages.dropFirst(prefix.count).compactMap(\.toolCallId))
        #expect(calledBefore.isDisjoint(with: answeredAfter))
    }

    @Test(arguments: [("load_tool", "Loaded search_references. Arguments JSON Schema: {}"),
                      ("load_skill", "Loaded skill: behavioral. Organize the answer as STAR.")])
    func loadPairsSurviveASummaryAndStayOutOfIt(loader: String, loaded: String) throws {
        let load = RawToolCall(id: "l1", name: loader,
                               argumentsJSON: #"{"name":"search_references"}"#)
        // Padded to one filler's length, so both cases land on the same greedy boundary.
        let result = loaded.padding(toLength: 401, withPad: " padding", startingAt: 0)
        let h = historyWithAPairAtTheGreedyBoundary(call: load, result: result)
        let before = h.estimatedTokens

        let prefix = try #require(h.compactionPrefix())

        #expect(prefix.count == Self.resultIndex + 1)
        #expect(prefix.messages.count == prefix.count - 2)
        #expect(!prefix.messages.contains { $0.toolCallId == "l1" })
        #expect(!prefix.messages.contains { $0.toolCalls?.contains(load) == true })

        guard case .accepted = h.compact(prefixCount: prefix.count, summary: "the gist",
                          revision: prefix.revision) else {
            Issue.record("expected the summary to reduce history"); return
        }

        let kept = h.snapshot()
        #expect(kept[0].text?.contains("the gist") == true)
        #expect(kept[1].toolCalls?.map(\.name) == [loader])
        #expect(kept[2].text == result)
        #expect(kept[2].toolCallId == "l1")
        #expect(h.estimatedTokens < before)
    }

    @Test func aPrefixOfNothingButRetainedPairsIsNotCompacted() {
        let h = CoachHistory()
        h.commit([
            .assistantToolCalls([RawToolCall(id: "l1", name: "load_tool",
                                             argumentsJSON: #"{"name":"search_references"}"#)]),
            .init(role: .tool, text: "Loaded search_references.", toolCallId: "l1"),
            .user(String(repeating: "x", count: 4000)),
        ])

        #expect(h.compactionPrefix() == nil)
        #expect(h.snapshot().count == 3)
    }

    @Test func compactReplacesPrefixWithSummary() {
        let h = CoachHistory()
        h.commit([.user(String(repeating: "old one ", count: 50)),
                  .user(String(repeating: "old two ", count: 50)), .user("recent")])
        let revision = h.compactionPrefix()!.revision
        guard case .accepted = h.compact(prefixCount: 2, summary: "the gist", revision: revision) else {
            Issue.record("expected the summary to reduce history"); return
        }
        let texts = h.snapshot().compactMap(\.text)
        #expect(texts.count == 2)
        #expect(texts[0].contains("the gist"))
        #expect(texts[0].contains("condensed"))
        #expect(texts[1] == "recent")
    }

    @Test func compactRejectsASummaryWrittenAgainstSupersededScreenText() {
        let h = CoachHistory()
        let ocr = JarvisPrompts.Coach.screenText([ScreenTextEvidence(
            text: "int hl = countHeight(root.left);",
            source: .onDeviceOCR,
            coverage: .currentViewport)], capturedAt: "00:10")
        h.commit([.init(role: .tool, text: ocr, toolCallId: "c1"), .user("first")])
        let stale = h.compactionPrefix()!

        // A newer capture lands while the summary is still being written.
        h.commit([.init(role: .tool, text: JarvisPrompts.Coach.screenText([ScreenTextEvidence(
            text: "fixed line", source: .onDeviceOCR, coverage: .currentViewport)],
            capturedAt: "00:42"),
                        toolCallId: "c2")])

        #expect(h.compact(prefixCount: stale.count, summary: "old screen said hl", revision: stale.revision) == .stale)
        let texts = h.snapshot().compactMap(\.text).joined(separator: "\n")
        #expect(!texts.contains("old screen said hl"))
        #expect(texts.contains(JarvisPrompts.Coach.supersededScreenTextStub))

        h.commit([.user(String(repeating: "Resolved discussion. ", count: 100)), .user("current tail")])
        let fresh = h.compactionPrefix()!
        guard case .accepted = h.compact(prefixCount: fresh.count, summary: "the gist", revision: fresh.revision) else {
            Issue.record("expected the summary to reduce history"); return
        }
        #expect(h.snapshot().compactMap(\.text).joined().contains("the gist"))
    }

    @Test func estimateGrowsWithContent() {
        let h = CoachHistory()
        let before = h.estimatedTokens
        h.commit([.user(String(repeating: "word ", count: 100))])
        let afterText = h.estimatedTokens
        #expect(afterText > before)
        h.commit([.userImage("QUJD")])
        #expect(h.estimatedTokens > afterText)
        // A committed image costs its stub text, not pixels.
        #expect(h.estimatedTokens < afterText + 100)
    }

    /// ASCII is estimated at 4 characters per token, other scripts at 1.
    @Test func estimateTreatsNonASCIITextConservatively() {
        let latin = CoachHistory()
        latin.commit([.user(String(repeating: "a", count: 100))])
        let chinese = CoachHistory()
        chinese.commit([.user(String(repeating: "中", count: 100))])

        #expect(latin.estimatedTokens == 25)
        #expect(chinese.estimatedTokens == 100)
    }
}
