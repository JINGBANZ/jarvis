import Foundation

/// Splits already-extracted plain text into chunks a few hundred words each, so a single search
/// result stays a bounded, affordable addition to a coaching request.
public enum PrepMaterialChunker {
    /// Accumulates whole paragraphs up to the target, starting a new chunk at Markdown headings
    /// so a short story and its caveats are not separated by the previous story's word budget.
    /// Pipe tables split between rows. An oversized prose paragraph or table row stays intact.
    public static func chunk(
        text: String,
        sourceDisplayName: String,
        targetWordCount: Int = 400
    ) -> [PrepMaterialChunk] {
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .flatMap { paragraph -> [String] in
                let lines = paragraph.components(separatedBy: "\n")
                // A question map can be one enormous paragraph. Keep each answer mapping intact
                // without making the entire table compete with every individual story in search.
                if lines.count > 1 && lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }) {
                    return lines
                }
                return [paragraph]
            }
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
            let prefix = paragraph.prefix(while: { $0 == "#" })
            if (1...6).contains(prefix.count), paragraph.dropFirst(prefix.count).first?.isWhitespace == true {
                flush()
            }
            let wordCount = paragraph.split(whereSeparator: \.isWhitespace).count
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
