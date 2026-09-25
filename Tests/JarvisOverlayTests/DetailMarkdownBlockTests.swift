import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

/// Every block kind `AttributedString(markdown:)` emits, drawn the way a Markdown reader expects.
@MainActor @Suite struct DetailMarkdownBlockTests {
    @Test func headingsAreSemiboldAndStepDownInSize() throws {
        let text = try render("# One\n\n## Two\n\n#### Four\n\nBody.")
        let one = try text.font("One"), two = try text.font("Two")
        let four = try text.font("Four"), body = try text.font("Body")
        #expect(one.pointSize > two.pointSize)
        #expect(two.pointSize > body.pointSize)
        #expect(four.pointSize == body.pointSize)
        #expect(four.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(!body.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func orderedListsKeepTheirNumbersAndNestedItemsIndent() throws {
        let text = try render("""
            3. Start at three
            4. Then four
               - nested bullet
               - another

            After.
            """)
        #expect(text.string == "3.\tStart at three\n4.\tThen four\n◦\tnested bullet\n◦\tanother\n\nAfter.")
        let outer = try text.paragraph("Then four"), nested = try text.paragraph("nested")
        #expect(outer.firstLineHeadIndent == 0)
        #expect(outer.tabStops.first?.location == outer.headIndent)
        #expect(nested.firstLineHeadIndent == outer.headIndent)
        #expect(nested.headIndent > outer.headIndent)
        #expect(nested.tabStops.first?.location == nested.headIndent)
        #expect(text.paragraphStyle(of: "After") == nil)
    }

    @Test func aWrappedItemLinesUpUnderItsText() throws {
        let view = try layOut("""
            - Keep a map from each letter to the index where it was last seen, and move the \
            left edge past it whenever the letter repeats inside the window.
            """, width: 260)
        let manager = try #require(view.layoutManager)
        let source = view.string as NSString
        let text = manager.glyphIndexForCharacter(at: source.range(of: "Keep").location)
        var lines: [NSRange] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            _, _, _, glyphs, _ in lines.append(glyphs)
        }
        #expect(lines.count > 1)
        let wrapped = try #require(lines.dropFirst().first)
        func x(_ glyph: Int) -> CGFloat {
            manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
                + manager.location(forGlyphAt: glyph).x
        }
        #expect(x(text) > 0)
        #expect(x(wrapped.location) == x(text))
    }

    @Test func aListItemsLaterParagraphHasNoSecondMarker() throws {
        let text = try render("""
            - first para

              second para
            - item two
            """)
        #expect(text.string == "•\tfirst para\nsecond para\n•\titem two")
        let first = try text.paragraph("first"), second = try text.paragraph("second")
        #expect(second.firstLineHeadIndent == first.headIndent)
        #expect(second.headIndent == first.headIndent)
    }

    @Test func quotesDrawABarDimTheirTextAndNest() throws {
        let text = try render("""
            > Outer line
            >
            > Second para
            > > inner

            After.
            """)
        #expect(text.string == "Outer line\n\nSecond para\n\ninner\n\nAfter.")
        let outer = try #require(try text.paragraph("Outer").textBlocks.first)
        #expect(!(outer is NSTextTableBlock))
        #expect(outer.width(for: .border, edge: .minX) > 0)
        #expect(outer.width(for: .border, edge: .maxX) == 0)
        #expect(try text.paragraph("Second").textBlocks.first === outer)
        let blank = (text.string as NSString).range(of: "\n\nSecond").location + 1
        #expect(text.paragraphStyle(at: blank)?.textBlocks.first === outer)
        let inner = try text.paragraph("inner").textBlocks
        #expect(inner.count == 2 && inner.first === outer)
        #expect(text.paragraphStyle(of: "After") == nil)
        let quoted = try #require(text.color("Outer")), plain = try #require(text.color("After"))
        #expect(quoted.alphaComponent < plain.alphaComponent)
    }

    @Test func aThematicBreakIsAFullWidthRule() throws {
        let view = try layOut("Above.\n\n---\n\nBelow.", width: 400)
        let text = view.attributedString()
        #expect(!text.string.contains("⸻"))
        let index = (text.string as NSString).range(of: "\n\nBelow").location - 1
        let rule = try #require(text.paragraphStyle(at: index)?.textBlocks.first)
        #expect(rule.width(for: .border, edge: .maxY) > 0)
        #expect(rule.width(for: .border, edge: .minX) == 0)
        // A block with no width shrinks to its content, a single space here.
        let manager = try #require(view.layoutManager), container = try #require(view.textContainer)
        let glyph = manager.glyphIndexForCharacter(at: index)
        #expect(manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).width
                > 0.9 * container.containerSize.width)
    }

    @Test func inlineStylesCombine() throws {
        let text = try render("***both*** and ~~gone~~ and `code`")
        let both = try text.font("both").fontDescriptor.symbolicTraits
        #expect(both.contains(.bold) && both.contains(.italic))
        let location = (text.string as NSString).range(of: "gone").location
        #expect(text.attribute(.strikethroughStyle, at: location, effectiveRange: nil) as? Int
                == NSUnderlineStyle.single.rawValue)
        #expect(try text.font("code").isFixedPitch)
    }

    /// `<br>` is how a model breaks a line inside a table cell; any other tag stays as written,
    /// because `List<Integer>` in prose parses as HTML too.
    @Test func lineBreaksAndBrBreakTheLineEvenInACell() throws {
        let text = try render("""
            one\\
            two

            | a | b |
            |---|---|
            | x<br>y | z |

            Use List<Integer> here.
            """)
        #expect(text.string.contains("one\u{2028}two"))
        #expect(text.string.contains("x\u{2028}y\n"))
        let x = try #require(try text.paragraph("x").textBlocks.first as? NSTextTableBlock)
        #expect(x.startingRow == 1 && x.startingColumn == 0)
        #expect(text.string.contains("Use List<Integer> here."))
    }

    @Test func htmlBlocksShowAsWritten() throws {
        let text = try render("<details>\n<summary>More</summary>\n</details>\n\nAfter.")
        #expect(text.string == "<details>\u{2028}<summary>More</summary>\u{2028}</details>\n\nAfter.")
    }

    /// The parser merges adjacent tags into one run and makes a tag on its own line an HTML block.
    @Test func everyBrTagBreaksTheLine() throws {
        #expect(try render("| a |\n|---|\n| x<br><br>y |").string.contains("x\u{2028}\u{2028}y"))
        #expect(try render("x<br><kbd>K</kbd>").string == "x\u{2028}<kbd>K</kbd>")
        #expect(try render("Line A\n\n<br>\n\nLine B").string == "Line A\n\n\u{2028}\n\nLine B")
    }

    @Test func aWideNumberStillLinesUpItsText() throws {
        let view = try layOut("""
            99. Short.
            100. Keep a map from each letter to the index where it was last seen, and move the \
            left edge past it whenever the letter repeats.
            """, width: 260)
        let manager = try #require(view.layoutManager)
        let source = view.string as NSString
        func x(_ glyph: Int) -> CGFloat {
            manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
                + manager.location(forGlyphAt: glyph).x
        }
        func x(_ word: String) -> CGFloat { x(manager.glyphIndexForCharacter(at: source.range(of: word).location)) }
        var lines: [NSRange] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            _, _, _, glyphs, _ in lines.append(glyphs)
        }
        #expect(lines.count > 2)
        #expect(x("Keep") == x("Short"))
        #expect(x(lines[2].location) == x("Keep"))
        let marker = (("100." as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16)])).width
        #expect(x("Keep") - x("100.") > marker)
    }

    private func render(_ markdown: String) throws -> NSAttributedString {
        let detail = try #require(ReplyDetail(markdown: markdown))
        guard case .prose(let prose)? = detail.segments.first, detail.segments.count == 1 else {
            Issue.record("a detail without fences is one prose segment")
            return NSAttributedString()
        }
        return DetailProseFormatting.render(prose, fontSize: 16)
    }

    private func layOut(_ markdown: String, width: CGFloat) throws -> NSTextView {
        let detail = try #require(ReplyDetail(markdown: markdown))
        let view = DetailView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        view.show(detail, stamp: "10:30:00", position: (0, 1), isHeld: false, isRolled: false,
                  fontSize: 16)
        view.layoutSubtreeIfNeeded()
        return try #require(textView(in: view))
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.accessibilityLabel() == "Detail" { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
}

private extension NSAttributedString {
    func paragraphStyle(at index: Int) -> NSParagraphStyle? {
        attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }

    func paragraphStyle(of word: String) -> NSParagraphStyle? {
        paragraphStyle(at: (string as NSString).range(of: word).location)
    }

    func paragraph(_ word: String) throws -> NSParagraphStyle {
        try #require(paragraphStyle(of: word))
    }

    func font(_ word: String) throws -> NSFont {
        try #require(attribute(.font, at: (string as NSString).range(of: word).location,
                               effectiveRange: nil) as? NSFont)
    }

    func color(_ word: String) -> NSColor? {
        attribute(.foregroundColor, at: (string as NSString).range(of: word).location,
                  effectiveRange: nil) as? NSColor
    }
}
