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
    /// stops being re-billed on every later request (the OCR tool-result text carries what the model
    /// reads; a fresh look is always one capture_screen away).
    @Test func imagesBecomeStubsAtCommit() {
        let h = CoachHistory()
        h.commit([.user("a"), .userImage("QUJD")])
        h.commit([.user("b"), .userImage("REVG")])
        let snap = h.snapshot()
        #expect(!snap.contains { $0.imageBase64JPEG != nil })
        #expect(snap.filter { ($0.text ?? "").contains("no longer available") }.count == 2)   // the stubs
        #expect(snap.compactMap(\.text).first == "a")   // non-image messages untouched
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

    @Test func compactReplacesPrefixWithSummary() {
        let h = CoachHistory()
        h.commit([.user("old one"), .user("old two"), .user("recent")])
        h.compact(prefixCount: 2, summary: "the gist")
        let texts = h.snapshot().compactMap(\.text)
        #expect(texts.count == 2)
        #expect(texts[0].contains("the gist"))
        #expect(texts[0].contains("condensed"))
        #expect(texts[1] == "recent")
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
}
