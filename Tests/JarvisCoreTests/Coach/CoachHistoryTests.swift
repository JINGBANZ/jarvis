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
        // The stub is a neutral marker, not an instruction — "call capture_screen" phrasing in
        // user-role history drove capture-on-every-quiet-turn in a live session audit.
        #expect(!snap.contains { ($0.text ?? "").contains("capture_screen") })
    }

    /// A new capture's OCR supersedes every earlier dump: older blocks collapse to a one-line stub
    /// (stale screen text misleads and re-bills), while text before the block and the newest OCR
    /// stay verbatim.
    @Test func newCaptureCollapsesSupersededOCR() {
        let ocr = { (body: String) in "\(JarvisPrompts.Coach.recognizedTextHeader)\n\(body)" }
        let h = CoachHistory()
        h.commit([.user("turn 1"),
                  .init(role: .tool, text: "screenshot captured\n\n\(ocr("if (min < sum)"))", toolCallId: "c1")])
        h.commit([.user("turn 2")])                                  // no capture: nothing collapses
        #expect(h.snapshot().contains { ($0.text ?? "").contains("if (min < sum)") })

        h.commit([.user(ocr("if (sum < min)"))])                     // hint-path OCR rides as a user message
        var texts = h.snapshot().compactMap(\.text)
        #expect(texts.contains("screenshot captured\n\n\(JarvisPrompts.Coach.supersededRecognizedTextStub)"))  // prefix survives
        #expect(!texts.joined().contains("if (min < sum)"))          // stale body gone
        #expect(texts.contains { $0.contains("if (sum < min)") })    // newest OCR verbatim

        h.commit([.init(role: .tool, text: "screenshot captured\n\n\(ocr("rewritten"))", toolCallId: "c2")])
        texts = h.snapshot().compactMap(\.text)
        #expect(texts.contains(JarvisPrompts.Coach.supersededRecognizedTextStub))                // the user-shaped OCR collapsed whole
        #expect(!texts.joined().contains("if (sum < min)"))
        #expect(texts.contains { $0.contains("rewritten") })
        #expect(h.snapshot().contains { $0.toolCallId == "c1" })     // tool-result pairing intact
    }

    /// A single tool loop may capture more than once; only the turn's own newest OCR survives
    /// verbatim — the earlier same-turn capture is as stale as any committed one.
    @Test func multiCaptureTurnKeepsOnlyItsNewestOCR() {
        let ocr = { (body: String) in "\(JarvisPrompts.Coach.recognizedTextHeader)\n\(body)" }
        let h = CoachHistory()
        h.commit([.user("turn"),
                  .init(role: .tool, text: "screenshot captured\n\n\(ocr("first look"))", toolCallId: "c1"),
                  .init(role: .tool, text: "screenshot captured\n\n\(ocr("second look"))", toolCallId: "c2")])
        let texts = h.snapshot().compactMap(\.text)
        #expect(!texts.joined().contains("first look"))
        #expect(texts.contains("screenshot captured\n\n\(JarvisPrompts.Coach.supersededRecognizedTextStub)"))
        #expect(texts.contains { $0.contains("second look") })
        #expect(h.snapshot().contains { $0.toolCallId == "c1" })     // pairing intact, text collapsed
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
