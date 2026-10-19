import Foundation

extension ReferenceChunker {
    /// Block boundaries only; blank lines and `#` comments inside a fence stay code.
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
                // Headings start a block without a blank line; consecutive headings stay together.
                if isMarkdownHeading(line), lines.contains(where: { !isMarkdownHeading($0) }) {
                    flush()
                }
                lines.append(line)
            }
        }
        flush()
        return paragraphs
    }

    static func isMarkdownHeading(_ paragraph: String) -> Bool {
        isMarkdownHeading(paragraph[..<(paragraph.firstIndex(of: "\n") ?? paragraph.endIndex)])
    }

    static func isMarkdownHeading(_ source: Substring) -> Bool {
        guard let line = markdownLine(source)?.unicodeScalars else { return false }
        let hashes = line.prefix(while: { $0 == "#" }).count
        return (1...6).contains(hashes)
            && (line.dropFirst(hashes).first.map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? true)
    }

    /// Nil unless an oversized table with leading and trailing pipes and a delimiter row; short
    /// tables share their section's budget.
    static func splitMarkdownTable(_ paragraph: String, targetWordCount: Int) -> [String]? {
        guard paragraph.split(whereSeparator: \.isWhitespace).count > targetWordCount else { return nil }
        let paragraphLines = paragraph.components(separatedBy: "\n")
        // Only headings may precede the rows; any other prose means this is not a table.
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
    private static func markdownLine(_ line: String) -> Substring? { markdownLine(line[...]) }

    private static func markdownLine(_ line: Substring) -> Substring? {
        let spaces = line.unicodeScalars.prefix(4).prefix(while: { $0 == " " }).count
        guard spaces <= 3 else { return nil }
        let content = line[line.unicodeScalars.index(line.startIndex, offsetBy: spaces)...]
        guard content.unicodeScalars.first != "\t" else { return nil }
        return content
    }

    static func fenceDelimiter(_ line: String) -> (marker: Character, count: Int, suffix: Substring)? {
        fenceDelimiter(line[...])
    }

    static func fenceDelimiter(_ line: Substring) -> (marker: Character, count: Int, suffix: Substring)? {
        guard let content = markdownLine(line), let marker = content.unicodeScalars.first,
              marker == "`" || marker == "~" else { return nil }
        let count = content.unicodeScalars.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        return (Character(String(marker)), count, content[content.unicodeScalars.index(content.startIndex, offsetBy: count)...])
    }
}
