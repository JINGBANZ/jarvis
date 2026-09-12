import Foundation

extension ActivityResponse {
    var plainText: String {
        var parts = ["Hint\n\(lines.joined(separator: "\n"))"]
        if let explanation { parts.append("Explanation\n\(explanation)") }
        if let code { parts.append("Code\n\(code.language)\n\(code.placement)\n\(code.code)") }
        return parts.joined(separator: "\n\n")
    }

    var markdown: String {
        var parts = ["### Hint\n\n\(lines.joined(separator: "\n"))"]
        if let explanation { parts.append("### Explanation\n\n\(explanation)") }
        if let code {
            // A snippet may itself contain Markdown fences; preserve it as one literal code block.
            var fence = "```"
            while code.code.contains(fence) { fence += "`" }
            parts.append("### Code\n\n\(code.language)\n\n\(code.placement)\n\n\(fence)\n\(code.code)\n\(fence)")
        }
        return parts.joined(separator: "\n\n")
    }

    var html: String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var result = "<section><h3>Hint</h3><p>\(escape(lines.joined(separator: "\n")))</p></section>"
        if let explanation {
            result += "<section><h3>Explanation</h3><p>\(escape(explanation))</p></section>"
        }
        if let code {
            result += "<section><h3>Code</h3><p>\(escape(code.language))</p>"
                + "<p>\(escape(code.placement))</p><pre><code>\(escape(code.code))</code></pre></section>"
        }
        return result
    }
}
