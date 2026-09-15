import Foundation

extension PrepMaterialChunker {
    /// A small block boundary reader, not a Markdown renderer. Unrecognized constructs remain
    /// prose. In particular, blank lines and heading-like comments inside a fence are code data.
    static func markdownParagraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var lines: [String] = []
        var fence: (marker: Character, count: Int)?

        func flush() {
            guard !lines.isEmpty else { return }
            paragraphs.append(lines.joined(separator: "\n"))
            lines.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            if let open = fence {
                lines.append(line)
                if let end = fenceDelimiter(line), end.marker == open.marker, end.count >= open.count,
                   end.suffix.trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                    flush()
                }
            } else if let start = fenceDelimiter(line),
                      start.marker != "`" || !start.suffix.contains("`") {
                flush()
                fence = (start.marker, start.count)
                lines.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                lines.append(line)
            }
        }
        flush()
        return paragraphs
    }

    static func isMarkdownHeading(_ paragraph: String) -> Bool {
        guard let first = paragraph.components(separatedBy: "\n").first,
              let line = markdownLine(first) else { return false }
        let hashes = line.prefix(while: { $0 == "#" })
        let rest = line.dropFirst(hashes.count)
        return (1...6).contains(hashes.count) && (rest.isEmpty || rest.first?.isWhitespace == true)
    }

    /// Only recognizes leading/trailing-pipe tables with an explicit delimiter row. Literal pipe
    /// text and unsupported table syntax retain ordinary paragraph behavior instead of guessing.
    static func splitMarkdownTable(_ paragraph: String, targetWordCount: Int) -> [String]? {
        // Short tables share their surrounding prose's budget, preserving the section's context
        // and caveats. Only an oversized table needs independent chunks with repeated headers.
        guard paragraph.split(whereSeparator: \.isWhitespace).count > targetWordCount else { return nil }
        let paragraphLines = paragraph.components(separatedBy: "\n")
        // A heading can introduce a table without a blank line. Keep only that recognized
        // prefix with its first rows; arbitrary prose must not be skipped or reinterpreted.
        let headings = paragraphLines.prefix(while: isMarkdownHeading)
        let lines = Array(paragraphLines.dropFirst(headings.count))
        guard lines.count >= 3,
              lines.allSatisfy({ line in
                  guard let content = markdownLine(line) else { return false }
                  return content.hasPrefix("|") && content.trimmingCharacters(in: .whitespaces).hasSuffix("|")
              }) else { return nil }
        let cells = lines[1].trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
            .split(separator: "|", omittingEmptySubsequences: false)
        let headerCells = lines[0].trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
            .split(separator: "|", omittingEmptySubsequences: false)
        guard cells.count == headerCells.count, cells.allSatisfy({ cell in
            var dashes = cell.trimmingCharacters(in: .whitespaces)[...]
            if dashes.first == ":" { dashes.removeFirst() }
            if dashes.last == ":" { dashes.removeLast() }
            return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
        }) else { return nil }

        let header = Array(lines.prefix(2))
        let headerWords = header.joined(separator: "\n").split(whereSeparator: \.isWhitespace).count
        var groups: [String] = []
        var rows: [String] = []
        var words = headerWords
        for row in lines.dropFirst(2) {
            let count = row.split(whereSeparator: \.isWhitespace).count
            if !rows.isEmpty && words + count > targetWordCount {
                groups.append((header + rows).joined(separator: "\n"))
                rows.removeAll()
                words = headerWords
            }
            rows.append(row)
            words += count
        }
        if !rows.isEmpty { groups.append((header + rows).joined(separator: "\n")) }
        if !headings.isEmpty, !groups.isEmpty {
            groups[0] = headings.joined(separator: "\n") + "\n" + groups[0]
        }
        return groups
    }

    /// Four leading spaces or a tab mark indented code, so Markdown heuristics must not strip them.
    private static func markdownLine(_ line: String) -> Substring? {
        let spaces = line.prefix(while: { $0 == " " })
        guard spaces.count <= 3 else { return nil }
        let content = line.dropFirst(spaces.count)
        guard content.first != "\t" else { return nil }
        return content
    }

    private static func fenceDelimiter(_ line: String) -> (marker: Character, count: Int, suffix: Substring)? {
        guard let content = markdownLine(line), let marker = content.first,
              marker == "`" || marker == "~" else { return nil }
        let count = content.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        return (marker, count, content.dropFirst(count))
    }
}
