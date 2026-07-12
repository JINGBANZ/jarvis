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

    /// The OCR sidecar is masked with its screenshot: on the capture_screen tool-result path, a stale
    /// turn's recognized text drops to the marker-free base line (call linkage preserved), while the
    /// newest turn keeps both its image and its OCR.
    @Test func staleOCRMaskedOnToolResultPath() {
        let h = CoachHistory()
        let marker = CoachDriver.recognizedTextMarker
        h.commit([
            .assistantToolCalls([RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(role: .tool, text: "screenshot captured\n\n\(marker)\nOLD_CODE_ONE", toolCallId: "c1"),
            .userImage("QUJD"),
        ])
        h.commit([
            .assistantToolCalls([RawToolCall(id: "c2", name: "capture_screen", argumentsJSON: "{}")]),
            .init(role: .tool, text: "screenshot captured\n\n\(marker)\nNEW_CODE_TWO", toolCallId: "c2"),
            .userImage("REVG"),
        ])
        let snap = h.snapshot()
        let allText = snap.compactMap(\.text).joined(separator: "\n")
        #expect(!allText.contains("OLD_CODE_ONE"))     // stale OCR gone
        #expect(allText.contains("NEW_CODE_TWO"))       // newest OCR intact
        // The newest screenshot survives as pixels; the stale one is stubbed.
        #expect(snap.filter { $0.imageBase64JPEG != nil }.count == 1)
        #expect(snap.last { $0.imageBase64JPEG != nil }?.imageBase64JPEG == "REVG")
        // Stale tool result keeps its call linkage but drops to the marker-free base line.
        #expect(snap.contains { $0.role == .tool && $0.toolCallId == "c1" && $0.text == "screenshot captured" })
        #expect(snap.contains { $0.role == .tool && $0.toolCallId == "c2" && ($0.text ?? "").contains(marker) })
    }

    /// The manual-hint path appends OCR as a standalone `.user` message right after its image; a stale
    /// one is stubbed away while the newest turn's image + OCR survive.
    @Test func staleOCRMaskedOnManualHintPath() {
        let h = CoachHistory()
        let marker = CoachDriver.recognizedTextMarker
        h.commit([.user("hint one"), .userImage("QUJD"), .user("\(marker)\nOLD_MANUAL_OCR")])
        h.commit([.user("hint two"), .userImage("REVG"), .user("\(marker)\nNEW_MANUAL_OCR")])
        let snap = h.snapshot()
        let allText = snap.compactMap(\.text).joined(separator: "\n")
        #expect(!allText.contains("OLD_MANUAL_OCR"))    // stale OCR gone
        #expect(allText.contains("NEW_MANUAL_OCR"))      // newest OCR intact
        #expect(snap.filter { $0.imageBase64JPEG != nil }.count == 1)
        #expect(snap.last { $0.imageBase64JPEG != nil }?.imageBase64JPEG == "REVG")
        #expect(!allText.contains(marker) || allText.contains("NEW_MANUAL_OCR"))   // only newest marker remains
    }

    /// A `stay_silent` / no-image turn carries no OCR and no screenshot — masking must leave it fully
    /// intact (no spurious stubbing of ordinary text).
    @Test func noImageTurnsAreUntouched() {
        let h = CoachHistory()
        h.commit([.user("heard: let's try two pointers"),
                  .init(role: .tool, text: "shown to the user", toolCallId: "s1")])
        let snap = h.snapshot()
        #expect(snap.compactMap(\.text) == ["heard: let's try two pointers", "shown to the user"])
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
