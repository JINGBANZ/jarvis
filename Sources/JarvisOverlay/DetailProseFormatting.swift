import AppKit
import JarvisCore

/// `AttributedString(markdown:)` records blocks as presentation intents, not styling, so a plain
/// bridge to `NSAttributedString` would run every paragraph and list item together.
@MainActor
enum DetailProseFormatting {
    static func render(_ prose: AttributedString, fontSize: CGFloat) -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor(white: 1, alpha: 0.86),
        ]
        let out = NSMutableAttributedString()
        var currentBlock: PresentationIntent?
        var started = false
        for run in prose.runs {
            let text = String(prose[run.range].characters)
            guard !text.isEmpty else { continue }
            let intent = run.presentationIntent
            if !started || intent != currentBlock {
                if started { out.append(NSAttributedString(string: "\n\n", attributes: body)) }
                if let intent, intent.components.contains(where: { $0.kind.isListItem }) {
                    out.append(NSAttributedString(string: "• ", attributes: body))
                }
                currentBlock = intent
                started = true
            }
            var attributes = body
            let inline = run.inlinePresentationIntent ?? []
            let isCodeBlock = intent?.components.contains { $0.kind.isCodeBlock } ?? false
            if inline.contains(.code) || isCodeBlock {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: max(9, fontSize - 1),
                                                                weight: .regular)
                attributes[.foregroundColor] = NSColor(white: 1, alpha: 0.94)
            } else if inline.contains(.stronglyEmphasized) {
                attributes[.font] = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
                if text == "Ask AI" || text == "Ask AI:" {
                    attributes[.foregroundColor] = NSColor(srgbRed: 128 / 255, green: 217 / 255,
                                                           blue: 238 / 255, alpha: 1)
                }
            } else if inline.contains(.emphasized) {
                attributes[.font] = NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: fontSize), toHaveTrait: .italicFontMask)
            }
            out.append(NSAttributedString(
                string: isCodeBlock ? text : text.replacingOccurrences(of: "\n", with: " "),
                attributes: attributes))
        }
        return out
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
