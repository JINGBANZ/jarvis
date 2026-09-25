import AppKit
import JarvisCore

/// `AttributedString(markdown:)` records blocks as presentation intents, not styling, so a plain
/// bridge to `NSAttributedString` would run every paragraph and list item together and scatter a
/// table's cells one per line.
@MainActor
enum DetailProseFormatting {
    static let foreground = NSColor(white: 1, alpha: 0.86)
    static let divider = NSColor(white: 1, alpha: 0.28)
    private static let quoted = NSColor(white: 1, alpha: 0.62)
    private static let code = NSColor(white: 1, alpha: 0.94)
    private static let askAI = NSColor(srgbRed: 128 / 255, green: 217 / 255, blue: 238 / 255, alpha: 1)
    private static let lineSeparator = "\u{2028}"

    static func render(_ prose: AttributedString, fontSize: CGFloat) -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: foreground,
        ]
        let out = NSMutableAttributedString()
        var styles = BlockStyles(fontSize: fontSize)
        var paragraph: (identity: Int?, style: NSParagraphStyle?, start: Int)?
        var above: [Block.Container]?
        var markedItems: Set<Int> = []
        var table: Table?
        func closeParagraph() {
            if let style = paragraph?.style, let start = paragraph?.start {
                out.addAttribute(.paragraphStyle, value: style,
                                 range: NSRange(location: start, length: out.length - start))
            }
            paragraph = nil
        }
        /// Ends what came before with its newline, then a blank line unless both sit in one list.
        /// The blank line keeps the quotes both share, so a quote's bar does not break.
        func separate(from containers: [Block.Container]) {
            defer { above = containers }
            guard let above else { return }
            if !out.mutableString.hasSuffix("\n") {
                out.append(NSAttributedString(string: "\n", attributes: body))
            }
            closeParagraph()
            guard !BlockStyles.areTight(above, containers) else { return }
            var blank = body
            let shared = zip(above, containers).prefix { $0 == $1 }.map(\.0)
            blank[.paragraphStyle] = styles.paragraph(shared)
            out.append(NSAttributedString(string: "\n", attributes: blank))
        }
        func begin(_ block: Block) {
            separate(from: block.containers)
            var marker: String?
            if case .item(let item, _, let text)? = block.containers.last, markedItems.insert(item).inserted {
                marker = text
            }
            paragraph = (block.identity,
                         styles.paragraph(block.containers, marker: marker != nil, rule: block.kind == .rule),
                         out.length)
            if let marker { out.append(NSAttributedString(string: marker + "\t", attributes: body)) }
        }
        func flushTable() {
            guard let cells = table else { return }
            separate(from: [])
            out.append(cells.render(body: body))
            table = nil
        }
        let runs = prose.runs.map { ($0, Block($0)) }
        for (_, block) in runs { styles.fit(block) }
        for (run, block) in runs {
            let text = String(prose[run.range].characters)
            guard !text.isEmpty else { continue }
            if let cell = run.presentationIntent.flatMap(Table.Cell.init) {
                if table?.identity != cell.table {
                    flushTable()
                    table = Table(cell)
                }
                table?.append(style(text, as: run, in: block, fontSize: fontSize,
                                    weight: cell.isHeader ? .semibold : .regular), to: cell)
                continue
            }
            flushTable()
            if paragraph == nil || paragraph?.identity != block.identity { begin(block) }
            out.append(style(text, as: run, in: block, fontSize: fontSize, weight: .regular))
        }
        flushTable()
        closeParagraph()
        return out
    }

    private static func style(_ text: String, as run: AttributedString.Runs.Run, in block: Block,
                              fontSize: CGFloat, weight: NSFont.Weight) -> NSAttributedString {
        // The rule is drawn by its paragraph's block border; a tiny space keeps the line thin.
        guard block.kind != .rule else {
            return NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 2)])
        }
        let inline = run.inlinePresentationIntent ?? []
        var size = fontSize
        var weight = weight
        if case .heading(let level) = block.kind {
            size = fontSize * headingScale(level)
            weight = .semibold
        }
        if inline.contains(.stronglyEmphasized) { weight = .semibold }
        let isCode = block.kind == .code || inline.contains(.code)
        var font = isCode
            ? NSFont.monospacedSystemFont(ofSize: max(9, size - 1), weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        if inline.contains(.emphasized) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isCode ? code : block.isQuoted ? quoted : foreground,
        ]
        if inline.contains(.stronglyEmphasized), text == "Ask AI" || text == "Ask AI:" {
            attributes[.foregroundColor] = askAI
        }
        if inline.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: displayed(text, inline: inline, in: block.kind),
                                  attributes: attributes)
    }

    /// A line break stays inside its paragraph, so it also works in a table cell.
    private static func displayed(_ text: String, inline: InlinePresentationIntent,
                                  in kind: Block.Kind) -> String {
        switch kind {
        case .code:
            return text.hasSuffix("\n") ? String(text.dropLast()) : text
        case .html:
            return breakingLines(text.trimmingCharacters(in: .newlines)
                .replacingOccurrences(of: "\n", with: lineSeparator))
        case .paragraph, .heading, .rule:
            break
        }
        if inline.contains(.lineBreak) { return lineSeparator }
        let flowed = text.replacingOccurrences(of: "\n", with: " ")
        return inline.contains(.inlineHTML) ? breakingLines(flowed) : flowed
    }

    /// Only `<br>` becomes a line break; any other tag shows as written, because `List<Integer>` in
    /// prose parses as HTML too.
    private static func breakingLines(_ html: String) -> String {
        html.replacingOccurrences(of: #"<br\s*/?>"#, with: lineSeparator,
                                  options: [.regularExpression, .caseInsensitive])
    }

    private static func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: 1.3
        case 2: 1.18
        case 3: 1.08
        default: 1
        }
    }
}
