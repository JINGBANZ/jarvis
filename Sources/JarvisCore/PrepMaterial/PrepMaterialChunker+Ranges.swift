import Foundation

extension PrepMaterialChunker {
    public struct Passage: Equatable, Sendable {
        public let range: Range<String.Index>
        public let offset: Int
        public let section: String?
    }

    /// Ranges refer to the unmodified source, including CRLF and indentation.
    public static func passages(text: String, markdown: Bool, targetScalars: Int = 4_000) -> [Passage] {
        var passages: [Passage] = []
        var section: String?
        var start = text.startIndex
        var scalarOffset = 0
        var count = 0
        var fence: (marker: Character, count: Int)?
        var hasContent = false
        func flush(_ end: String.Index) {
            guard start < end else { return }
            if hasContent { passages.append(Passage(range: start..<end, offset: scalarOffset, section: section)) }
            scalarOffset += text[start..<end].unicodeScalars.count
            start = end; count = 0; hasContent = false
        }
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let end = text.unicodeScalars[lineStart...].firstIndex(of: "\n").map { text.unicodeScalars.index(after: $0) } ?? text.endIndex
            let line = text[lineStart..<end]
            let heading = markdown && fence == nil && isMarkdownHeading(line)
            let blank = line.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
            if heading, hasContent { flush(lineStart) }
            if heading { section = String(String.UnicodeScalarView(line.unicodeScalars.prefix(256))).trimmingCharacters(in: .newlines) }
            let wasInFence = fence != nil
            if markdown, let open = fence {
                if let close = fenceDelimiter(line), close.marker == open.marker, close.count >= open.count,
                   close.suffix.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) { fence = nil }
            } else if markdown, let open = fenceDelimiter(line), open.marker != "`" || !open.suffix.unicodeScalars.contains("`") {
                if hasContent { flush(lineStart) }
                fence = (open.marker, open.count)
            }
            let lineCount = line.unicodeScalars.count
            if count + lineCount > targetScalars, hasContent, fence == nil, !wasInFence { flush(lineStart) }
            count += lineCount
            hasContent = hasContent || !markdown || !blank && !heading
            // Even a hostile single line/fence has a bounded indexing allocation.
            while count > 16_000 {
                let cut = text.unicodeScalars.index(start, offsetBy: 16_000)
                let remaining = count - 16_000
                flush(cut)
                count = remaining
                hasContent = remaining > 0 && (!markdown || !blank && !heading)
            }
            if count >= targetScalars, hasContent, fence == nil,
               wasInFence || blank || line.unicodeScalars.drop(while: { CharacterSet.whitespaces.contains($0) }).first == "|" {
                flush(end)
            }
            lineStart = end
        }
        flush(text.endIndex)
        return passages
    }
}
