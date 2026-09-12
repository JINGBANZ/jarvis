import Testing
@testable import JarvisCore

@Suite struct CoachHistoryTests {
    @Test func commitAppendsInOrder() {
        let h = CoachHistory()
        h.commit([.user("one")], at: 0)
        h.commit([.user("two")], at: 0)
        #expect(h.snapshot().compactMap(\.text) == ["one", "two"])
    }

    /// Observation masking: no screenshot survives commit as pixels — each becomes a text stub so it
    /// stops being re-billed on every later request (the OCR tool-result text carries what the model
    /// reads; a fresh look is always one capture_screen away).
    @Test func imagesBecomeStubsAtCommit() {
        let h = CoachHistory()
        h.commit([.user("a"), .userImage("QUJD")], at: 0)
        h.commit([.user("b"), .userImage("REVG")], at: 0)
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
                  .init(role: .tool, text: "screenshot captured\n\n\(ocr("if (min < sum)"))", toolCallId: "c1")], at: 0)
        h.commit([.user("turn 2")], at: 0)                                  // no capture: nothing collapses
        #expect(h.snapshot().contains { ($0.text ?? "").contains("if (min < sum)") })

        h.commit([.user(ocr("if (sum < min)"))], at: 0)                     // hint-path OCR rides as a user message
        var texts = h.snapshot().compactMap(\.text)
        #expect(texts.contains("screenshot captured\n\n\(JarvisPrompts.Coach.supersededRecognizedTextStub)"))  // prefix survives
        #expect(!texts.joined().contains("if (min < sum)"))          // stale body gone
        #expect(texts.contains { $0.contains("if (sum < min)") })    // newest OCR verbatim

        h.commit([.init(role: .tool, text: "screenshot captured\n\n\(ocr("rewritten"))", toolCallId: "c2")], at: 0)
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
                  .init(role: .tool, text: "screenshot captured\n\n\(ocr("second look"))", toolCallId: "c2")], at: 0)
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
                  .init(role: .tool, text: "screenshot captured", toolCallId: "c1")], at: 0)
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
        h.commit([.user("a"), .rawItems([#"{"type":"reasoning","id":"rs_1"}"#]), .user("b")], at: 0)
        #expect(h.snapshot().compactMap(\.text) == ["a", "b"])
        #expect(!h.snapshot().contains { $0.rawItemsJSON != nil || $0.toolCalls != nil })
    }

    /// The compaction prefix always leaves the newest message verbatim and hands out at least one —
    /// a single oversized message must still be compactable once a second one exists.
    @Test func compactionPrefixBoundsRespectTheTail() {
        let h = CoachHistory()
        #expect(h.compactionPrefix() == nil)                       // empty: nothing to split
        h.commit([.user("only")], at: 0)
        #expect(h.compactionPrefix() == nil)                       // one message: nothing to split
        h.commit([.user(String(repeating: "x", count: 4000)), .user("tail")], at: 0)
        let prefix = h.compactionPrefix()
        #expect(prefix != nil)
        #expect(prefix!.count < h.snapshot().count)                // the tail stays verbatim
    }

    @Test func compactReplacesPrefixWithSummary() {
        let h = CoachHistory()
        h.commit([.user("old one"), .user("old two"), .user("recent")], at: 0)
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
        let ocr = JarvisPrompts.Coach.recognizedText("int hl = countHeight(root.left);")
        h.commit([.init(role: .tool, text: ocr, toolCallId: "c1"), .user("first")], at: 0)
        let stale = h.compactionPrefix()!

        // A newer capture lands while the summary is still being written.
        h.commit([.init(role: .tool, text: JarvisPrompts.Coach.recognizedText("fixed line"),
                        toolCallId: "c2")], at: 0)

        #expect(!h.compact(prefixCount: stale.count, summary: "old screen said hl", revision: stale.revision))
        let texts = h.snapshot().compactMap(\.text).joined(separator: "\n")
        #expect(!texts.contains("old screen said hl"))                     // summary dropped
        #expect(texts.contains(JarvisPrompts.Coach.supersededRecognizedTextStub))  // collapse survives

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
        h.commit([.user(String(repeating: "word ", count: 100))], at: 0)
        let afterText = h.estimatedTokens
        #expect(afterText > before)
        h.commit([.userImage("QUJD")], at: 0)
        #expect(h.estimatedTokens > afterText)                    // the stub still counts…
        #expect(h.estimatedTokens < afterText + 100)              // …but nowhere near image cost
    }

    /// The compaction trigger must not apply an English chars/4 estimate to Chinese text. Equal
    /// character counts deliberately produce a more conservative estimate for non-ASCII scripts.
    @Test func estimateTreatsNonASCIITextConservatively() {
        let latin = CoachHistory()
        latin.commit([.user(String(repeating: "a", count: 100))], at: 0)
        let chinese = CoachHistory()
        chinese.commit([.user(String(repeating: "中", count: 100))], at: 0)

        #expect(latin.estimatedTokens == 25)
        #expect(chinese.estimatedTokens == 100)
    }

    // MARK: - Screen-text staleness

    /// The newest OCR is the one block superseding never reaches, so with no further capture it used
    /// to describe "the screen" for the rest of the session. A live session audit caught the coach
    /// answering a freshly asked coding question against the previous question's screen.
    @Test func staleScreenTextExpiresToAStub() {
        let h = CoachHistory()
        h.commit([.init(role: .tool,
                        text: "[05:00] screenshot captured\n\n\(JarvisPrompts.Coach.recognizedText("Question 1"))",
                        toolCallId: "c1")], at: 300)

        #expect(h.expireStaleScreenText(olderThan: 120, at: 400) == false)   // 100s old: still the screen
        #expect(h.snapshot().compactMap(\.text).contains { $0.contains("Question 1") })

        #expect(h.expireStaleScreenText(olderThan: 120, at: 425) == true)    // 125s old: retired
        let text = h.snapshot().compactMap(\.text).joined()
        #expect(!text.contains("Question 1"))
        #expect(text.contains(JarvisPrompts.Coach.staleRecognizedTextStub))
        #expect(text.contains("[05:00] screenshot captured"))                // when that look happened survives
        // Neutral marker, like the superseded and image stubs: a "look again" cue repeated in
        // user-role history drove capture-on-every-quiet-turn in an earlier session audit.
        #expect(!text.contains("capture_screen"))
    }

    /// Expiry is idempotent, and a fresh capture restarts the clock rather than inheriting the old
    /// one's age — otherwise the look the coach just took would expire on the next request.
    @Test func freshCaptureRestartsTheStalenessClock() {
        let h = CoachHistory()
        h.commit([.init(role: .tool,
                        text: "[05:00] screenshot captured\n\n\(JarvisPrompts.Coach.recognizedText("old"))",
                        toolCallId: "c1")], at: 300)
        #expect(h.expireStaleScreenText(olderThan: 120, at: 425) == true)
        #expect(h.expireStaleScreenText(olderThan: 120, at: 999) == false)   // nothing left to retire

        h.commit([.init(role: .tool,
                        text: "[16:39] screenshot captured\n\n\(JarvisPrompts.Coach.recognizedText("new"))",
                        toolCallId: "c2")], at: 999)
        #expect(h.expireStaleScreenText(olderThan: 120, at: 1_050) == false)
        #expect(h.snapshot().compactMap(\.text).contains { $0.contains("new") })
    }

    /// Compaction reads the history, then writes its summary much later. Expiry rewrites committed
    /// messages in place, so a summary written across one must be rejected — applying it would put
    /// the screen text expiry just retired straight back into history.
    @Test func compactRejectsASummaryWrittenAcrossAnExpiry() {
        let h = CoachHistory()
        h.commit([.init(role: .tool,
                        text: "[05:00] screenshot captured\n\n\(JarvisPrompts.Coach.recognizedText("Question 1"))",
                        toolCallId: "c1"), .user("first")], at: 300)
        h.commit([.user("second")], at: 310)
        let prefix = h.compactionPrefix()!
        #expect(h.expireStaleScreenText(olderThan: 120, at: 425) == true)
        #expect(h.compact(prefixCount: prefix.count, summary: "…", revision: prefix.revision) == false)
    }
}
