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
        if let lexer = hashOpensAComment(in: snippet.language) ? hashAndSlashLexer : slashLexer {
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

    // Both variants are compiled once: the panel re-lexes the snippet on every frame of a resize
    // drag, and building an NSRegularExpression per call made that drag pay for the whole grammar.
    private static let slashLexer = lexer(hashComments: false)
    private static let hashAndSlashLexer = lexer(hashComments: true)

    /// `#` opens a comment in these languages only. Elsewhere it is load-bearing syntax
    /// (`#include`, `#define`, `#available`, `#if`), and coloring such a line inert would tell a
    /// candidate under pressure that it does nothing. `language` is free text from the model, so
    /// match case-insensitively and accept the short forms it tends to use.
    private static let hashCommentLanguages: Set<String> = [
        "python", "py", "python3", "ruby", "rb", "shell", "sh", "bash", "zsh", "fish",
        "perl", "pl", "yaml", "yml", "toml", "r", "make", "makefile", "cmake", "dockerfile",
    ]

    private static func hashOpensAComment(in language: String) -> Bool {
        hashCommentLanguages.contains(language.lowercased())
    }

    /// A single ordered lexer prevents keywords inside strings or comments being recolored.
    /// Keep quoted tokens on one line: a lifetime or truncated string must not color later code.
    /// The two variants differ only inside group 1, so the color dispatch above stays the same.
    private static func lexer(hashComments: Bool) -> NSRegularExpression? {
        let comment = hashComments ? #"(//[^\n]*|#[^\n]*)"# : #"(//[^\n]*)"#
        let rest = #"|("(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*')|\b(func|def|let|var|const|return|if|else|for|while|in|class|struct|enum|guard|import|from|public|private|static|new|nil|null|true|false|None|True|False|async|await|throw|try|catch|break|continue)\b|\b\d+(?:\.\d+)?\b"#
        return try? NSRegularExpression(pattern: #"(?m)"# + comment + rest)
    }
}
