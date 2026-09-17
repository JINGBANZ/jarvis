import Foundation

/// Okapi BM25, deliberately not embeddings: it needs no network, API key, or dependency.
public struct PrepMaterialIndex: PrepMaterialSearching {
    private struct IndexedChunk {
        let chunk: PrepMaterialChunk
        let termFrequency: [String: Int]
        let length: Int
    }

    private let indexed: [IndexedChunk]
    private let averageChunkLength: Double
    private let documentFrequency: [String: Int]

    private static let k1 = 1.2
    private static let b = 0.75
    private static let resultLimit = 3

    public init(chunks: [PrepMaterialChunk]) {
        var documentFrequency: [String: Int] = [:]
        self.indexed = chunks.map { chunk in
            let tokens = Self.tokenize(chunk.text)
            var frequency: [String: Int] = [:]
            for token in tokens { frequency[token, default: 0] += 1 }
            for token in Set(tokens) { documentFrequency[token, default: 0] += 1 }
            return IndexedChunk(chunk: chunk, termFrequency: frequency, length: tokens.count)
        }
        self.documentFrequency = documentFrequency
        self.averageChunkLength = indexed.isEmpty
            ? 0
            : Double(indexed.map(\.length).reduce(0, +)) / Double(indexed.count)
    }

    public func search(query: String) -> [PrepMaterialSearchResult] {
        guard !indexed.isEmpty else { return [] }
        let queryTerms = Set(Self.tokenize(query))
        guard !queryTerms.isEmpty else { return [] }

        return indexed
            .map { entry in (entry, score(queryTerms: queryTerms, entry: entry)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.resultLimit)
            .map {
                PrepMaterialSearchResult(
                    sourceDisplayName: $0.0.chunk.sourceDisplayName,
                    text: $0.0.chunk.text)
            }
    }

    private func score(queryTerms: Set<String>, entry: IndexedChunk) -> Double {
        let length = Double(entry.length)
        let chunkCount = Double(indexed.count)

        var total = 0.0
        for term in queryTerms {
            guard let termFrequency = entry.termFrequency[term], termFrequency > 0 else { continue }
            let documentsContaining = Double(documentFrequency[term] ?? 0)
            let idf = log((chunkCount - documentsContaining + 0.5) / (documentsContaining + 0.5) + 1)
            let numerator = Double(termFrequency) * (Self.k1 + 1)
            let denominator = Double(termFrequency)
                + Self.k1 * (1 - Self.b + Self.b * length / max(averageChunkLength, 1))
            total += idf * numerator / denominator
        }
        return total
    }

    /// Dropping one-letter tokens ("a", "I") stands in for a stopword list.
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }
}
