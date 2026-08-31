import Foundation

/// Splits already-extracted plain text into chunks a few hundred words each, so a single search
/// result stays a bounded, affordable addition to a coaching request.
public enum PrepMaterialChunker {
    /// Chunks are built by accumulating whole paragraphs (blank-line-separated) until adding the
    /// next one would exceed `targetWordCount`, so a chunk boundary never splits a paragraph in two.
    /// A single paragraph longer than `targetWordCount` becomes its own oversized chunk rather than
    /// being split mid-thought.
    public static func chunk(
        text: String,
        sourceDisplayName: String,
        targetWordCount: Int = 400
    ) -> [PrepMaterialChunk] {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return [] }

        var chunks: [PrepMaterialChunk] = []
        var current: [String] = []
        var currentWordCount = 0

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(PrepMaterialChunk(
                sourceDisplayName: sourceDisplayName,
                text: current.joined(separator: "\n\n")))
            current.removeAll()
            currentWordCount = 0
        }

        for paragraph in paragraphs {
            let wordCount = paragraph.split(separator: " ").count
            if currentWordCount + wordCount > targetWordCount, !current.isEmpty {
                flush()
            }
            current.append(paragraph)
            currentWordCount += wordCount
        }
        flush()
        return chunks
    }
}
