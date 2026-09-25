import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct DetailRenderingTests {
    @MainActor @Test(arguments: ["'", "\""])
    func unmatchedQuotesDoNotColorAcrossLines(_ quote: String) throws {
        let block = try #require(CodeBlock(language: "text",
            code: "prefix \(quote)a\nreturn value\nend \(quote)"))
        let text = CodeBlockFormatting.render(block, fontSize: 16)
        let baseline = try #require(CodeBlock(language: "text", code: "return value"))
        let expected = CodeBlockFormatting.render(baseline, fontSize: 16)
        let keyword = (block.code as NSString).range(of: "return")
        #expect((text.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? NSColor)
            == (expected.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor))
    }

    /// A preprocessor directive is load-bearing; coloring it inert would be worse than no coloring.
    @MainActor @Test func hashOpensACommentOnlyInHashCommentLanguages() throws {
        let plain = try firstColor("cpp", "include <vector>")
        let comment = try firstColor("swift", "// count seen")
        #expect(comment != plain)
        #expect(try firstColor("cpp", "#include <vector>") == plain)
        #expect(try firstColor("c", "#define MAX 100") == plain)
        #expect(try firstColor("swift", "#available(macOS 14, *)") == plain)
        #expect(try firstColor("python", "# count seen") == comment)
        #expect(try firstColor("py", "# count seen") == comment)
        #expect(try firstColor("bash", "# count seen") == comment)
    }

    @MainActor @Test func aDiffBlockTintsAdditionsAndStrikesRemovals() throws {
        let block = try #require(CodeBlock(language: "diff",
            code: " for right, ch in enumerate(s):\n-    if ch in last_seen:\n+    if ch in last_seen and last_seen[ch] >= left:"))
        let text = CodeBlockFormatting.render(block, fontSize: 16)
        let source = block.code as NSString
        let removed = source.range(of: "-    if ch in last_seen:")
        let added = source.range(of: "+    if ch in last_seen and")
        let context = source.range(of: " for right")
        #expect(text.attribute(.strikethroughStyle, at: removed.location, effectiveRange: nil) != nil)
        #expect(text.attribute(.backgroundColor, at: added.location, effectiveRange: nil) != nil)
        #expect(text.attribute(.strikethroughStyle, at: added.location, effectiveRange: nil) == nil)
        #expect(text.attribute(.backgroundColor, at: context.location, effectiveRange: nil) == nil)

        let plain = try #require(CodeBlock(language: "python", code: "-x\n+y"))
        let plainText = CodeBlockFormatting.render(plain, fontSize: 16)
        #expect(plainText.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil)
    }

    @MainActor @Test func anUnchangedDetailKeepsItsRenderedText() throws {
        let detail = try #require(ReplyDetail(markdown: "Start here.\n\n```swift\nlet value = 1\nreturn value\n```"))
        let view = DetailView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        show(detail, in: view)
        view.layoutSubtreeIfNeeded()
        let marker = NSAttributedString.Key("JarvisRenderMarker")
        let storage = try #require(textView(in: view, labeled: "Code block")?.textStorage)
        storage.addAttribute(marker, value: true, range: NSRange(location: 0, length: storage.length))

        show(detail, in: view)
        view.layoutSubtreeIfNeeded()
        #expect(view.codeText.attribute(marker, at: 0, effectiveRange: nil) as? Bool == true)

        show(detail, in: view, fontSize: 14)
        #expect(view.codeText.attribute(marker, at: 0, effectiveRange: nil) == nil)
    }

    @MainActor @Test func proseKeepsStructureAndDropsLinks() throws {
        let detail = try #require(ReplyDetail(markdown: """
            Two things matter here.

            - Track `last_seen` per letter.
            - Move `left` forward only.

            See [the notes](https://example.com).
            """))
        let view = DetailView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        show(detail, in: view)
        let text = view.proseText
        #expect(text.contains("Two things matter here."))
        #expect(text.contains("• Track last_seen per letter."))
        #expect(text.contains("• Move left forward only."))
        #expect(text.contains("the notes"))
        #expect(!text.contains("example.com"))
        guard case .prose(let prose)? = detail.segments.first, detail.segments.count == 1 else {
            Issue.record("a detail without fences is one prose segment")
            return
        }
        let rendered = DetailProseFormatting.render(prose, fontSize: 16)
        let inline = (rendered.string as NSString).range(of: "last_seen")
        let font = try #require(rendered.attribute(.font, at: inline.location, effectiveRange: nil) as? NSFont)
        #expect(font.isFixedPitch)
    }

    /// Each cell arrives as its own presentation intent; drawn one per paragraph a table is a column
    /// of 28 lines, so cells go into one `NSTextTable` and the paragraphs around it stay as they were.
    @MainActor @Test func aTableIsAGridBetweenItsParagraphs() throws {
        let detail = try #require(ReplyDetail(markdown: """
            Trace of Example 1:

            | step | l1 digit | carry out |
            |---|:---:|---:|
            | first | `two` | **zero** |
            | second | four | six |

            Result: `[7,0,8]`.
            """))
        let view = DetailView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        show(detail, in: view)
        view.layoutSubtreeIfNeeded()
        let prose = try #require(textView(in: view, labeled: "Detail"))
        #expect(prose.string.hasPrefix("Trace of Example 1:\n\n"))
        #expect(prose.string.hasSuffix("\n\nResult: [7,0,8]."))
        let text = prose.attributedString()
        let source = text.string as NSString
        func paragraph(_ word: String) -> NSParagraphStyle? {
            text.attribute(.paragraphStyle, at: source.range(of: word).location,
                           effectiveRange: nil) as? NSParagraphStyle
        }
        func font(_ word: String) throws -> NSFont {
            try #require(text.attribute(.font, at: source.range(of: word).location,
                                        effectiveRange: nil) as? NSFont)
        }
        func block(_ word: String) throws -> NSTextTableBlock {
            try #require(paragraph(word)?.textBlocks.first as? NSTextTableBlock)
        }
        #expect(paragraph("Trace")?.textBlocks.isEmpty != false)
        #expect(paragraph("Result")?.textBlocks.isEmpty != false)
        let step = try block("step")
        let carry = try block("carry out")
        let four = try block("four")
        #expect(step.table === four.table)
        #expect(step.table.numberOfColumns == 3)
        #expect(step.startingRow == 0 && step.startingColumn == 0)
        #expect(carry.startingRow == 0 && carry.startingColumn == 2)
        #expect(four.startingRow == 2 && four.startingColumn == 1)
        #expect(paragraph("first")?.alignment == .left)
        #expect(paragraph("four")?.alignment == .center)
        #expect(paragraph("six")?.alignment == .right)
        #expect(try font("step").fontDescriptor.symbolicTraits.contains(.bold))
        #expect(try !font("second").fontDescriptor.symbolicTraits.contains(.bold))
        #expect(try font("two").isFixedPitch)
        #expect(try font("zero").fontDescriptor.symbolicTraits.contains(.bold))

        let manager = try #require(prose.layoutManager)
        func line(_ word: String) -> NSRect {
            let glyph = manager.glyphIndexForCharacter(at: source.range(of: word).location)
            return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        #expect(line("step").minY == line("carry out").minY)
        #expect(line("step").maxX <= line("carry out").minX)
        #expect(line("step").maxY <= line("first").minY)
        #expect(line("first").minY == line("zero").minY)
        #expect(line("first").maxY <= line("second").minY)
        #expect(line("second").minY == line("six").minY)
        #expect(line("Result").minY >= line("six").maxY)
    }

    /// The parser emits no run for an empty cell, so the cell's paragraph is only its newline.
    @MainActor @Test func anEmptyLastCellKeepsItsBlockAndTheSpacingAfterTheTable() throws {
        let detail = try #require(ReplyDetail(markdown: """
            | a | b |
            |---|---|
            | x | |

            After.
            """))
        guard case .prose(let prose)? = detail.segments.first, detail.segments.count == 1 else {
            Issue.record("a detail without fences is one prose segment")
            return
        }
        let rendered = DetailProseFormatting.render(prose, fontSize: 16)
        #expect(rendered.string == "a\nb\nx\n\n\nAfter.")
        func block(at index: Int) -> NSTextTableBlock? {
            (rendered.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?
                .textBlocks.first as? NSTextTableBlock
        }
        let x = try #require(block(at: 4))
        let empty = try #require(block(at: 6))
        #expect(x.table === empty.table)
        #expect(empty.startingRow == 1 && empty.startingColumn == 1)
        #expect(block(at: 7) == nil)
        #expect(block(at: 8) == nil)
    }

    @MainActor @Test func oneDocumentCanCarryBothACodeBlockAndADiagram() throws {
        let detail = try #require(ReplyDetail(markdown: """
            Sketch it, then start here.

            ```mermaid
            flowchart LR
            a[Client] --> b[API]
            ```

            ```python
            total = 0
            ```
            """))
        let view = DetailView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        show(detail, in: view)
        view.layoutSubtreeIfNeeded()
        #expect(view.codeText.string == "total = 0")
        #expect(view.proseText.contains("Sketch it, then start here."))
        #expect(view.showsDiagram)
    }

    @MainActor @Test func syntaxForegroundMeetsContrastOnCodeAndDiffBackgrounds() throws {
        let block = try #require(CodeBlock(language: "diff",
            code: "+let n = 42 // count\n-return \"value\""))
        let text = CodeBlockFormatting.render(block, fontSize: 16)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
            let foreground = attributes[.foregroundColor] as! NSColor
            let background = attributes[.backgroundColor] as? NSColor ?? DetailView.background
            let ratio = (luminance(foreground) + 0.05) / (luminance(background) + 0.05)
            #expect(ratio >= 4.5)
        }
    }

    @MainActor @Test func theDetailBoxIsOpaqueReadableAndTooltipFree() throws {
        let detail = try #require(ReplyDetail(markdown: "```swift\n  let value = 1\n  return value\n```"))
        let view = DetailView(frame: NSRect(x: 0, y: 0, width: 300, height: 130))
        show(detail, in: view, fontSize: 24)
        #expect(view.codeText.string == "  let value = 1\n  return value")
        #expect(view.layer?.backgroundColor?.alpha == 1)
        let font = try #require(view.codeText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize >= 12)
        #expect(font.pointSize <= 18)
        #expect(font.isFixedPitch)
        for button in [view.previousButton, view.nextButton, view.pinButton, view.dismissButton] {
            #expect(button.toolTip == nil)
            #expect(button.accessibilityLabel()?.isEmpty == false)
        }
    }

    @MainActor @Test func hintsCarryAMarkerAndAHiddenBoxScrubsTheDetail() throws {
        let box = OverlayBoxPanel()
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        let detail = try #require(ReplyDetail(markdown: "Use a window.\n\n```python\nleft = 0\n```"))
        #expect(box.deliver(["Move the left edge."], detail: detail) == detail)
        #expect(box.currentText.contains("Move the left edge."))
        #expect(box.currentText.contains("detail below"))
        #expect(!box.currentText.contains("left = 0"))
        #expect(box.currentDetailCodeText.string == "left = 0")
        #expect(box.currentSharingType == .none)

        _ = box.deliver(["A plain hint."], detail: nil)
        #expect(box.currentDetail == detail, "a hint without a detail leaves the box as it is")

        box.clickCollapseButton()
        #expect(box.deliver(["While collapsed."], detail: ReplyDetail(markdown: "Not shown.")) == nil)
        box.clickCollapseButton()
        #expect(box.currentDetail == detail)
    }

    @MainActor @Test func aDetailWithNothingLeftToDrawDoesNotTakeTheBox() throws {
        let box = OverlayBoxPanel()
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        let good = try #require(ReplyDetail(markdown: "Here.\n\n```python\nleft = 0\n```"))
        _ = box.deliver(["First."], detail: good)
        let bad = try #require(ReplyDetail(markdown: "```mermaid\nsequenceDiagram\nA->>B: x\n```"))
        #expect(!bad.hasContent)
        #expect(box.deliver(["Second."], detail: bad) == nil)
        #expect(box.currentDetail == good)
    }

    @MainActor @Test func clearAndStopEmptyBothBoxes() throws {
        let box = OverlayBoxPanel()
        box.setSessionLive(true)
        let detail = try #require(ReplyDetail(markdown: "A window is the current range."))
        _ = box.deliver(["Move the left edge."], detail: detail)
        #expect(box.detailCount == 1)
        box.clickClearButton()
        #expect(box.currentText.isEmpty)
        #expect(box.detailCount == 0)
        #expect(box.currentDetail == nil)

        _ = box.deliver(["Again."], detail: detail)
        box.setSessionLive(false)
        #expect(!box.isPanelVisible)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        #expect(box.detailCount == 0)
        #expect(box.currentDetail == nil)
    }

    @MainActor private func show(_ detail: ReplyDetail, in view: DetailView, fontSize: CGFloat = 18) {
        view.show(detail, stamp: "10:30:00", position: (0, 1), isHeld: false, isRolled: false,
                  fontSize: fontSize)
    }

    @MainActor private func textView(in view: NSView, labeled label: String) -> NSTextView? {
        if let text = view as? NSTextView, text.accessibilityLabel() == label { return text }
        return view.subviews.lazy.compactMap { textView(in: $0, labeled: label) }.first
    }
}

@MainActor private func firstColor(_ language: String, _ code: String) throws -> NSColor {
    let block = try #require(CodeBlock(language: language, code: code))
    return try #require(CodeBlockFormatting.render(block, fontSize: 16)
        .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
}

private func luminance(_ color: NSColor) -> CGFloat {
    let rgb = color.usingColorSpace(.sRGB)!
    func linear(_ component: CGFloat) -> CGFloat {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
        + 0.0722 * linear(rgb.blueComponent)
}
