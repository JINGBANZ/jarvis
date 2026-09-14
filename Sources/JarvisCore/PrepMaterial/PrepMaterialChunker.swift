import Foundation

/// Splits extracted prep text into searchable chunks without interpreting non-Markdown sources.
public enum PrepMaterialChunker {
    /// Keeps prose paragraphs intact. Markdown sections start fresh; fenced code remains intact,
    /// and recognized pipe tables split between rows with their column headers repeated.
    /// Oversized paragraphs, code blocks, and individual table rows can exceed the target.
    /// Pending headings stay with their following content even when that exceeds the target.
    public static func chunk(
        text: String,
        sourceDisplayName: String,
        targetWordCount: Int = 400
    ) -> [PrepMaterialChunk] {
        // The index builder supplies the original filename, including the source format. Extracted
        // PDF/Word text can contain literal # and | characters without any Markdown semantics.
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
            // A heading-only hit has no evidence for retrieval. Keep consecutive headings with
            // their first content block rather than emitting them at section or budget boundaries.
            if isMarkdown, isMarkdownHeading(paragraph), currentHasContent { flush() }
            let wordCount = paragraph.split(whereSeparator: \.isWhitespace).count
            if currentWordCount + wordCount > targetWordCount, currentHasContent { flush() }
            current.append(paragraph)
            currentWordCount += wordCount
            currentHasContent = currentHasContent || !isMarkdown
                || !paragraph.components(separatedBy: "\n").allSatisfy(isMarkdownHeading)
        }
        flush()
        return chunks
    }
}
