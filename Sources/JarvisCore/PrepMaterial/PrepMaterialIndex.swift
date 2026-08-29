import Foundation

/// A local, in-memory Okapi BM25 index over already-chunked prep-material text.
///
/// Deliberately not semantic/embedding search (see the #219 decision log): the corpus is personal
/// interview notes, not a large external knowledge base, and keyword ranking needs no network call,
/// no API key, and no dependency — so it works identically regardless of which brain provider is
/// configured. Building the index is pure, fast, in-memory work with no I/O; reading the user's files
/// and extracting text from each format happens once, earlier, at the macOS edge in JarvisApp.
public struct PrepMaterialIndex: PrepMaterialSearching {
    private let chunks: [PrepMaterialChunk]
    private let chunkTermFrequencies: [[String: Int]]
    private let chunkLengths: [Int]
    private let averageChunkLength: Double
    private let documentFrequency: [String: Int]

    private static let k1 = 1.2
    private static let b = 0.75
    private static let resultLimit = 3

    public init(chunks: [PrepMaterialChunk]) {
        self.chunks = chunks

        var termFrequencies: [[String: Int]] = []
        var lengths: [Int] = []
        var documentFrequency: [String: Int] = [:]

        for chunk in chunks {
            let tokens = Self.tokenize(chunk.text)
            lengths.append(tokens.count)
            var frequency: [String: Int] = [:]
            for token in tokens { frequency[token, default: 0] += 1 }
            termFrequencies.append(frequency)
            for token in Set(tokens) { documentFrequency[token, default: 0] += 1 }
        }

        self.chunkTermFrequencies = termFrequencies
        self.chunkLengths = lengths
        self.averageChunkLength = lengths.isEmpty
            ? 0
            : Double(lengths.reduce(0, +)) / Double(lengths.count)
        self.documentFrequency = documentFrequency
    }

    public func search(query: String) -> [PrepMaterialSearchResult] {
        guard !chunks.isEmpty else { return [] }
        let queryTerms = Set(Self.tokenize(query))
        guard !queryTerms.isEmpty else { return [] }

        return chunks.indices
            .map { index in (index, score(queryTerms: queryTerms, chunkIndex: index)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.resultLimit)
            .map {
                PrepMaterialSearchResult(
                    sourceDisplayName: chunks[$0.0].sourceDisplayName,
                    text: chunks[$0.0].text)
            }
    }

    private func score(queryTerms: Set<String>, chunkIndex: Int) -> Double {
        let frequency = chunkTermFrequencies[chunkIndex]
        let length = Double(chunkLengths[chunkIndex])
        let chunkCount = Double(chunks.count)

        var total = 0.0
        for term in queryTerms {
            guard let termFrequency = frequency[term], termFrequency > 0 else { continue }
            let documentsContaining = Double(documentFrequency[term] ?? 0)
            let idf = log((chunkCount - documentsContaining + 0.5) / (documentsContaining + 0.5) + 1)
            let numerator = Double(termFrequency) * (Self.k1 + 1)
            let denominator = Double(termFrequency)
                + Self.k1 * (1 - Self.b + Self.b * length / max(averageChunkLength, 1))
            total += idf * numerator / denominator
        }
        return total
    }

    /// Lowercased alphanumeric runs, length > 1 — a minimal stand-in for a stopword list that at
    /// least drops single letters ("a", "I") from dominating scores.
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }
}
