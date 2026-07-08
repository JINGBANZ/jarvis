import Testing
@testable import JarvisCore

@Suite struct CoachHistoryTests {
    @Test func commitAppendsInOrder() {
        let h = CoachHistory()
        h.commit([.user("one")])
        h.commit([.user("two")])
        #expect(h.snapshot().compactMap(\.text) == ["one", "two"])
    }

    /// Observation masking: only the newest screenshot survives as pixels; older ones become stubs
    /// so they stop being re-billed on every later request.
    @Test func olderImagesBecomeStubs() {
        let h = CoachHistory()
        h.commit([.user("a"), .userImage("QUJD")])
        h.commit([.user("b"), .userImage("REVG")])
        let snap = h.snapshot()
        #expect(snap.filter { $0.imageBase64JPEG != nil }.count == 1)
        #expect(snap.last { $0.imageBase64JPEG != nil }?.imageBase64JPEG == "REVG")   // the newest
        #expect(snap.contains { ($0.text ?? "").contains("no longer available") })    // the stub
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

    /// The estimate scales with text and counts images — precision doesn't matter, monotonicity does.
    @Test func estimateGrowsWithContent() {
        let h = CoachHistory()
        let before = h.estimatedTokens
        h.commit([.user(String(repeating: "word ", count: 100))])
        let afterText = h.estimatedTokens
        #expect(afterText > before)
        h.commit([.userImage("QUJD")])
        #expect(h.estimatedTokens > afterText + 1_000)   // an image is ~1.5k tokens, not ~1
    }
}
