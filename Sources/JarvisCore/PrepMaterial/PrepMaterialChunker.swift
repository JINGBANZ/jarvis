import Foundation

public enum PrepMaterialChunker {
    /// Paragraphs, fences, and table rows are never split, so a chunk can exceed the target.
    /// Trailing headings with no content are dropped.
    public static func chunk(
        text: String,
        sourceDisplayName: String,
        targetWordCount: Int = 400
    ) -> [PrepMaterialChunk] {
        // Extracted PDF and Word text can contain literal # and | with no Markdown meaning.
        let isMarkdown = (sourceDisplayName as NSString).pathExtension.lowercased() == "md"
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let paragraphs = isMarkdown ? markdownParagraphs(normalized) : normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var chunks: [PrepMaterialChunk] = []
        var current: [String] = []
        var currentWordCount = 0
        var currentHasContent = false

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(PrepMaterialChunk(
                sourceDisplayName: sourceDisplayName, text: current.joined(separator: "\n\n")))
            current.removeAll()
            currentWordCount = 0
            currentHasContent = false
        }

        for paragraph in paragraphs {
            if isMarkdown, let tables = splitMarkdownTable(paragraph, targetWordCount: targetWordCount) {
                if currentHasContent { flush() }
                for table in tables {
                    current.append(table)
                    flush()
                }
                continue
            }
            // A heading-only hit is useless, so headings stay with their first content block.
            if isMarkdown, isMarkdownHeading(paragraph), currentHasContent { flush() }
            let wordCount = paragraph.split(whereSeparator: \.isWhitespace).count
            if currentWordCount + wordCount > targetWordCount, currentHasContent { flush() }
            current.append(paragraph)
            currentWordCount += wordCount
            currentHasContent = currentHasContent || !isMarkdown
                || !paragraph.components(separatedBy: "\n").allSatisfy(isMarkdownHeading)
        }
        if currentHasContent { flush() }
        return chunks
    }
}
