import AppKit
import JarvisCore

/// `AttributedString(markdown:)` records blocks as presentation intents, not styling, so a plain
/// bridge to `NSAttributedString` would run every paragraph and list item together and scatter a
/// table's cells one per line.
@MainActor
enum DetailProseFormatting {
    static let foreground = NSColor(white: 1, alpha: 0.86)

    static func render(_ prose: AttributedString, fontSize: CGFloat) -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: foreground,
        ]
        let out = NSMutableAttributedString()
        var currentBlock: PresentationIntent?
        var started = false
        var table: Table?
        func startBlock() {
            if started { out.append(NSAttributedString(string: "\n\n", attributes: body)) }
            started = true
        }
        func flushTable() {
            guard let cells = table else { return }
            startBlock()
            out.append(cells.render(body: body))
            table = nil
        }
        for run in prose.runs {
            let text = String(prose[run.range].characters)
            guard !text.isEmpty else { continue }
            let intent = run.presentationIntent
            let cell = intent.flatMap(Table.Cell.init)
            let styled = style(text, as: run, fontSize: fontSize,
                               weight: cell?.isHeader == true ? .semibold : .regular)
            if let cell {
                if table?.identity != cell.table {
                    flushTable()
                    table = Table(cell)
                }
                table?.append(styled, to: cell)
                continue
            }
            flushTable()
            if !started || intent != currentBlock {
                startBlock()
                if let intent, intent.components.contains(where: { $0.kind.isListItem }) {
                    out.append(NSAttributedString(string: "• ", attributes: body))
                }
                currentBlock = intent
            }
            out.append(styled)
        }
        flushTable()
        return out
    }

    private static func style(_ text: String, as run: AttributedString.Runs.Run, fontSize: CGFloat,
                              weight: NSFont.Weight) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: foreground,
        ]
        let inline = run.inlinePresentationIntent ?? []
        let isCodeBlock = run.presentationIntent?.components.contains { $0.kind.isCodeBlock } ?? false
        if inline.contains(.code) || isCodeBlock {
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: max(9, fontSize - 1), weight: weight)
            attributes[.foregroundColor] = NSColor(white: 1, alpha: 0.94)
        } else if inline.contains(.stronglyEmphasized) {
            attributes[.font] = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            if text == "Ask AI" || text == "Ask AI:" {
                attributes[.foregroundColor] = NSColor(srgbRed: 128 / 255, green: 217 / 255,
                                                       blue: 238 / 255, alpha: 1)
            }
        } else if inline.contains(.emphasized) {
            attributes[.font] = NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: fontSize, weight: weight), toHaveTrait: .italicFontMask)
        }
        return NSAttributedString(
            string: isCodeBlock ? text : text.replacingOccurrences(of: "\n", with: " "),
            attributes: attributes)
    }
}

private extension PresentationIntent.Kind {
    var isListItem: Bool {
        if case .listItem = self { return true }
        return false
    }

    var isCodeBlock: Bool {
        if case .codeBlock = self { return true }
        return false
    }
}
