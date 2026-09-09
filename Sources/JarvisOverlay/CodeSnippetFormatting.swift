import AppKit
import JarvisCore

/// Lightweight lexical accents only: unknown languages remain fully readable plain code.
@MainActor
enum CodeSnippetFormatting {
    static func render(_ snippet: CodeSnippet, fontSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: snippet.code, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor(white: 0.94, alpha: 1),
        ])
        let source = snippet.code as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        // A single ordered lexer prevents keywords inside strings or comments being recolored.
        // Keep quoted tokens on one line: a lifetime or truncated string must not color later code.
        let pattern = #"(?m)(//[^\n]*|#[^\n]*)|("(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*')|\b(func|def|let|var|const|return|if|else|for|while|in|class|struct|enum|guard|import|from|public|private|static|new|nil|null|true|false|None|True|False|async|await|throw|try|catch|break|continue)\b|\b\d+(?:\.\d+)?\b"#
        if let lexer = try? NSRegularExpression(pattern: pattern) {
            for match in lexer.matches(in: snippet.code, range: fullRange) {
                let color: NSColor
                if match.range(at: 1).location != NSNotFound {
                    color = NSColor(srgbRed: 0.62, green: 0.74, blue: 0.68, alpha: 1)
                } else if match.range(at: 2).location != NSNotFound {
                    color = NSColor(srgbRed: 0.69, green: 0.88, blue: 0.65, alpha: 1)
                } else if match.range(at: 3).location != NSNotFound {
                    color = NSColor(srgbRed: 0.82, green: 0.72, blue: 1, alpha: 1)
                } else {
                    color = NSColor(srgbRed: 1, green: 0.81, blue: 0.57, alpha: 1)
                }
                result.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        var offset = 0
        for (index, line) in snippet.code.components(separatedBy: "\n").enumerated() {
            let count = (line as NSString).length
            if snippet.highlightedLines.contains(index + 1), count > 0 {
                result.addAttribute(.backgroundColor,
                    value: NSColor(srgbRed: 0.25, green: 0.18, blue: 0.07, alpha: 1),
                    range: NSRange(location: offset, length: count))
            }
            offset += count + 1
        }
        return result
    }
}
