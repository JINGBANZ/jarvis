import Testing
@testable import JarvisCore

@Suite struct CoachHistoryTests {
    @Test func commitAppendsInOrder() {
        let h = CoachHistory()
        h.commit([.user("one")])
        h.commit([.user("two")])
        #expect(h.snapshot().compactMap(\.text) == ["one", "two"])
    }

    /// Observation masking: no screenshot survives commit as pixels — each becomes a text stub so it
    /// stops being re-billed on every later request (the text evidence carries what the model
    /// reads; a fresh look is always one capture_screen away).
    @Test func imagesBecomeStubsAtCommit() {
        let h = CoachHistory()
        h.commit([.user("a"), .userImage("QUJD")])
        h.commit([.user("b"), .userImage("REVG")])
        let snap = h.snapshot()
        #expect(!snap.contains { $0.imageBase64JPEG != nil })
        #expect(snap.filter { ($0.text ?? "").contains("no longer available") }.count == 2)   // the stubs
        #expect(snap.compactMap(\.text).first == "a")   // non-image messages untouched
        // The stub is a neutral marker, not an instruction — "call capture_screen" phrasing in
        // user-role history drove capture-on-every-quiet-turn in a live session audit.
        #expect(!snap.contains { ($0.text ?? "").contains("capture_screen") })
    }

    /// A new capture supersedes every earlier screen-text dump: older blocks collapse to a one-line
    /// stub (stale screen text misleads and re-bills), while text before the block and the newest evidence
    /// stay verbatim.
    @Test func newCaptureCollapsesSupersededScreenText() {
        let ocr = { (body: String) in "\(JarvisPrompts.Coach.screenTextHeader)\n\(body)" }
        let h = CoachHistory()
        h.commit([.user("turn 1"),
                  .init(role: .tool, text: "screenshot captured\n\n\(ocr("if (min < sum)"))", toolCallId: "c1")])
        h.commit([.user("turn 2")])                                  // no capture: nothing collapses
        #expect(h.snapshot().contains { ($0.text ?? "").contains("if (min < sum)") })

        h.commit([.user(ocr("if (sum < min)"))])                     // hint-path OCR rides as a user message
        var texts = h.snapshot().compactMap(\.text)
        #expect(texts.contains("screenshot captured\n\n\(JarvisPrompts.Coach.supersededScreenTextStub)"))  // prefix survives
        #expect(!texts.joined().contains("if (min < sum)"))          // stale body gone
        #expect(texts.contains { $0.contains("if (sum < min)") })    // newest OCR verbatim

        h.commit([.init(role: .tool, text: "screenshot captured\n\n\(ocr("rewritten"))", toolCallId: "c2")])
        texts = h.snapshot().compactMap(\.text)
        #expect(texts.contains(JarvisPrompts.Coach.supersededScreenTextStub))                // the user-shaped OCR collapsed whole
        #expect(!texts.joined().contains("if (sum < min)"))
        #expect(texts.contains { $0.contains("rewritten") })
        #expect(h.snapshot().contains { $0.toolCallId == "c1" })     // tool-result pairing intact
    }

    /// A single tool loop may capture more than once; only the turn's newest text evidence survives
    /// verbatim — the earlier same-turn capture is as stale as any committed one.
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
        #expect(h.snapshot().contains { $0.toolCallId == "c1" })     // pairing intact, text collapsed
    }

    /// Committed screen text keeps its words but stops claiming to be the current screen, so a later
    /// request that needs the screen is free to look again. The capture's own attempt read it as
    /// current; only memory relabels it.
    @Test func committedScreenTextIsLabeledAsAnEarlierCapture() throws {
        let current = JarvisPrompts.Coach.screenText([
            ScreenTextEvidence(text: "intervals.sort()", source: .onDeviceOCR, coverage: .currentViewport),
            ScreenTextEvidence(text: "Merge Intervals", source: .browserAccessibility,
                               coverage: .activeTabAccessibilityTree),
        ])
        #expect(current.contains(JarvisPrompts.Coach.currentOCRSource))
        let h = CoachHistory()
        h.commit([.user("turn"),
                  .init(role: .tool, text: "screenshot captured\n\n\(current)", toolCallId: "c1")])

        let committed = try #require(h.snapshot().first { $0.toolCallId == "c1" }?.text)
        #expect(committed.contains("intervals.sort()") && committed.contains("Merge Intervals"))
        #expect(committed.contains(JarvisPrompts.Coach.earlierOCRSource))
        #expect(committed.contains(JarvisPrompts.Coach.earlierAccessibilitySource))
        #expect(!committed.contains(JarvisPrompts.Coach.currentOCRSource))
        #expect(!committed.contains(JarvisPrompts.Coach.currentAccessibilitySource))
    }

    /// Raw passthrough items live only inside their turn's tool loop — commit converts them: the
    /// function_call survives as the synthetic id-less call (so the committed tool result never
    /// orphans) and reasoning is dropped; later turns don't need it and a model switch would
    /// invalidate it anyway.
    @Test func rawPassthroughItemsAreConvertedAtCommit() {
        let h = CoachHistory()
        h.commit([.user("a"),
                  .rawItems([#"{"type":"reasoning","id":"rs_1","encrypted_content":"blob"}"#,
                             #"{"type":"function_call","id":"fc_1","call_id":"c1","name":"capture_screen","arguments":"{}"}"#]),
                  .init(role: .tool, text: "screenshot captured", toolCallId: "c1")])
        let snap = h.snapshot()
        #expect(!snap.contains { $0.rawItemsJSON != nil })                       // nothing verbatim survives
        #expect(!snap.contains { ($0.toolCalls?.first?.argumentsJSON ?? "").contains("blob") })
        #expect(snap.compactMap(\.toolCalls).flatMap { $0 }
                == [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")])
        #expect(snap.contains { $0.role == .tool && $0.toolCallId == "c1" })     // the pair stays whole
    }

    /// A passthrough message with no function_call in it (reasoning only) leaves no trace at commit —
    /// there is nothing a later turn could use.
    @Test func reasoningOnlyPassthroughIsDroppedWholeAtCommit() {
        let h = CoachHistory()
        h.commit([.user("a"), .rawItems([#"{"type":"reasoning","id":"rs_1"}"#]), .user("b")])
        #expect(h.snapshot().compactMap(\.text) == ["a", "b"])
        #expect(!h.snapshot().contains { $0.rawItemsJSON != nil || $0.toolCalls != nil })
    }

    /// The compaction prefix always leaves the newest message verbatim and hands out at least one —
    /// a single oversized message must still be compactable once a second one exists.
    /// Silence needs no memory, even a `stay_silent` call the turn went past: every such call leaves
    /// with the results answering it, from plain call lists and passthrough items alike, while a
    /// call beside it keeps its own result.
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
            .rawItems([#"{"type":"function_call","call_id":"q2","name":"stay_silent","arguments":"{}"}"#]),
            .init(role: .tool, text: "not executed", toolCallId: "q2"),
            .assistantToolCalls([RawToolCall(id: "s1", name: "speak", argumentsJSON: #"{"lines":["Hi."]}"#)]),
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
        #expect(h.compactionPrefix() == nil)                       // empty: nothing to split
        h.commit([.user("only")])
        #expect(h.compactionPrefix() == nil)                       // one message: nothing to split
        h.commit([.user(String(repeating: "x", count: 4000)), .user("tail")])
        let prefix = h.compactionPrefix()
        #expect(prefix != nil)
        #expect(prefix!.count < h.snapshot().count)                // the tail stays verbatim
    }

    /// Ten same-cost messages with a tool call and its result at indices 5 and 6. The greedy 60%
    /// budget lands *between* them: five fillers fit, the cheap call fits, the result does not.
    /// That is the only boundary the snapping exists for, so a fixture that does not reach it
    /// tests nothing — which is why both tests below assert where the boundary actually fell.
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

    /// A summary that replaced an assistant tool call while its result stayed behind would leave an
    /// orphaned output, which providers reject. The boundary moves rather than splitting the pair.
    @Test func theCompactionPrefixNeverSplitsACallFromItsResult() throws {
        let call = RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")
        let h = historyWithAPairAtTheGreedyBoundary(
            call: call, result: String(repeating: "y", count: 400))

        let prefix = try #require(h.compactionPrefix())

        // Snapped forward over the result. Without snapping this is `callIndex + 1`, which is the
        // regression: the call inside the summarized span, its answer left behind.
        #expect(prefix.count == Self.resultIndex + 1)
        let messages = h.snapshot()
        let calledBefore = Set(messages.prefix(prefix.count).flatMap { $0.toolCalls ?? [] }.map(\.id))
        let answeredAfter = Set(messages.dropFirst(prefix.count).compactMap(\.toolCallId))
        #expect(calledBefore.isDisjoint(with: answeredAfter))
    }

    /// A loaded tool's schema and guidance, and a loaded skill's body, are the only copy the model
    /// has. Summarizing them away would leave it holding a capability it can no longer use
    /// correctly, so the pair survives verbatim under the summary, and the summarizer never sees it
    /// twice.
    @Test(arguments: [("load_tool", "Loaded search_prep_notes. Arguments JSON Schema: {}"),
                      ("load_skill", "Loaded skill: behavioral. Organize the answer as STAR.")])
    func loadPairsSurviveASummaryAndStayOutOfIt(loader: String, loaded: String) throws {
        let load = RawToolCall(id: "l1", name: loader,
                               argumentsJSON: #"{"name":"search_prep_notes"}"#)
        // Padded to one filler's length, so both cases land on the same greedy boundary.
        let result = loaded.padding(toLength: 401, withPad: " padding", startingAt: 0)
        let h = historyWithAPairAtTheGreedyBoundary(call: load, result: result)
        let before = h.estimatedTokens

        let prefix = try #require(h.compactionPrefix())

        // The pair is inside the span being replaced, which is what makes the rest meaningful.
        #expect(prefix.count == Self.resultIndex + 1)
        // ...and withheld from the summarizer, so its text is never folded into the summary that
        // will sit directly above the verbatim copy.
        #expect(prefix.messages.count == prefix.count - 2)
        #expect(!prefix.messages.contains { $0.toolCallId == "l1" })
        #expect(!prefix.messages.contains { $0.toolCalls?.contains(load) == true })

        #expect(h.compact(prefixCount: prefix.count, summary: "the gist",
                          revision: prefix.revision))

        let kept = h.snapshot()
        #expect(kept[0].text?.contains("the gist") == true)
        #expect(kept[1].toolCalls?.map(\.name) == [loader])
        #expect(kept[2].text == result)
        #expect(kept[2].toolCallId == "l1")
        #expect(h.estimatedTokens < before)
    }

    /// A budget that reaches only a retained pair leaves nothing to summarize. Compacting it would
    /// send the summarizer an empty prompt and stack a summary of nothing above the pair it kept.
    @Test func aPrefixOfNothingButRetainedPairsIsNotCompacted() {
        let h = CoachHistory()
        h.commit([
            .assistantToolCalls([RawToolCall(id: "l1", name: "load_tool",
                                             argumentsJSON: #"{"name":"search_prep_notes"}"#)]),
            .init(role: .tool, text: "Loaded search_prep_notes.", toolCallId: "l1"),
            .user(String(repeating: "x", count: 4000)),
        ])

        #expect(h.compactionPrefix() == nil)
        #expect(h.snapshot().count == 3)
    }

    @Test func compactReplacesPrefixWithSummary() {
        let h = CoachHistory()
        h.commit([.user("old one"), .user("old two"), .user("recent")])
        let revision = h.compactionPrefix()!.revision
        #expect(h.compact(prefixCount: 2, summary: "the gist", revision: revision))
        let texts = h.snapshot().compactMap(\.text)
        #expect(texts.count == 2)
        #expect(texts[0].contains("the gist"))
        #expect(texts[0].contains("condensed"))
        #expect(texts[1] == "recent")
    }

    /// Compaction reads history on one task and writes the summary back much later from another. A
    /// capture committed in between collapses superseded OCR *inside* the snapshotted prefix, so
    /// applying the older summary would reintroduce the screen text that collapse just retired —
    /// exactly the stale-context failure OCR invalidation exists to prevent. The summary is dropped
    /// and history left untouched; the next completed attempt compacts from a fresh prefix.
    @Test func compactRejectsASummaryWrittenAgainstSupersededScreenText() {
        let h = CoachHistory()
        let ocr = JarvisPrompts.Coach.screenText([ScreenTextEvidence(
            text: "int hl = countHeight(root.left);",
            source: .onDeviceOCR,
            coverage: .currentViewport)])
        h.commit([.init(role: .tool, text: ocr, toolCallId: "c1"), .user("first")])
        let stale = h.compactionPrefix()!

        // A newer capture lands while the summary is still being written.
        h.commit([.init(role: .tool, text: JarvisPrompts.Coach.screenText([ScreenTextEvidence(
            text: "fixed line", source: .onDeviceOCR, coverage: .currentViewport)]),
                        toolCallId: "c2")])

        #expect(!h.compact(prefixCount: stale.count, summary: "old screen said hl", revision: stale.revision))
        let texts = h.snapshot().compactMap(\.text).joined(separator: "\n")
        #expect(!texts.contains("old screen said hl"))                     // summary dropped
        #expect(texts.contains(JarvisPrompts.Coach.supersededScreenTextStub))  // collapse survives

        // A fresh prefix compacts normally.
        let fresh = h.compactionPrefix()!
        #expect(h.compact(prefixCount: fresh.count, summary: "the gist", revision: fresh.revision))
        #expect(h.snapshot().compactMap(\.text).joined().contains("the gist"))
    }

    /// The estimate scales with text — precision doesn't matter, monotonicity does. A committed
    /// image counts as its stub text, not as pixels (it was stubbed on the way in).
    @Test func estimateGrowsWithContent() {
        let h = CoachHistory()
        let before = h.estimatedTokens
        h.commit([.user(String(repeating: "word ", count: 100))])
        let afterText = h.estimatedTokens
        #expect(afterText > before)
        h.commit([.userImage("QUJD")])
        #expect(h.estimatedTokens > afterText)                    // the stub still counts…
        #expect(h.estimatedTokens < afterText + 100)              // …but nowhere near image cost
    }

    /// The compaction trigger must not apply an English chars/4 estimate to Chinese text. Equal
    /// character counts deliberately produce a more conservative estimate for non-ASCII scripts.
    @Test func estimateTreatsNonASCIITextConservatively() {
        let latin = CoachHistory()
        latin.commit([.user(String(repeating: "a", count: 100))])
        let chinese = CoachHistory()
        chinese.commit([.user(String(repeating: "中", count: 100))])

        #expect(latin.estimatedTokens == 25)
        #expect(chinese.estimatedTokens == 100)
    }
}
