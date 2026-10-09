import Foundation

/// Okapi BM25, deliberately not embeddings: it needs no network, API key, or dependency.
public struct PrepMaterialIndex: PrepMaterialSearching {
    private struct IndexedChunk {
        let chunk: PrepMaterialChunk
        let documentID: String
        let termFrequency: [String: Int]
        let length: Int
    }

    private let indexed: [IndexedChunk]
    private let documents: [PrepMaterialDocument]
    private let averageChunkLength: Double
    private let documentFrequency: [String: Int]

    private static let k1 = 1.2
    private static let b = 0.75
    private static let resultLimit = 3

    public init(chunks: [PrepMaterialChunk]) {
        let names = chunks.map(\.sourceDisplayName).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        let documents = names.map { name in
            PrepMaterialDocument(sourceDisplayName: name,
                                 text: chunks.filter { $0.sourceDisplayName == name }.map(\.text)
                                     .joined(separator: "\n\n"))
        }
        let ids = Dictionary(uniqueKeysWithValues: documents.map { ($0.sourceDisplayName, $0.id) })
        self.init(documents: documents, chunks: chunks.map { ($0, ids[$0.sourceDisplayName]!) })
    }

    public init(documents: [PrepMaterialDocument]) {
        self.init(documents: documents, chunks: documents.flatMap { document in
            PrepMaterialChunker.chunk(text: document.text, sourceDisplayName: document.sourceDisplayName)
                .map { ($0, document.id) }
        })
    }

    private init(documents: [PrepMaterialDocument], chunks: [(PrepMaterialChunk, String)]) {
        self.documents = documents
        var documentFrequency: [String: Int] = [:]
        self.indexed = chunks.map { chunk, documentID in
            let tokens = Self.tokenize(chunk.text)
            var frequency: [String: Int] = [:]
            for token in tokens { frequency[token, default: 0] += 1 }
            for token in Set(tokens) { documentFrequency[token, default: 0] += 1 }
            return IndexedChunk(chunk: chunk, documentID: documentID,
                                termFrequency: frequency, length: tokens.count)
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
        var unmatched = query
        var matchedNames: Set<String> = []
        let uniqueNames: Set<String> = Set(documents.map(\.sourceDisplayName))
        let filenames = uniqueNames.sorted { (left: String, right: String) -> Bool in
            if left.count == right.count { return left < right }
            return left.count > right.count
        }
        // Consume longer names first so their suffixes do not select unrelated files.
        for name in filenames where !name.isEmpty {
            if unmatched.range(of: name, options: .caseInsensitive) != nil {
                matchedNames.insert(name)
                unmatched = unmatched.replacingOccurrences(of: name, with: " ", options: .caseInsensitive)
            }
        }
        let named = documents.filter { matchedNames.contains($0.sourceDisplayName) }
        let ids = Set(named.map(\.id))
        let filenameTerms = Set(named.flatMap { Self.tokenize($0.sourceDisplayName) })
        let contentTerms = queryTerms.subtracting(filenameTerms)
        let candidates = indexed.enumerated().filter { named.isEmpty || ids.contains($0.element.documentID) }

        let scored: [(IndexedChunk, Double, Int)] = candidates
            .map { position, entry in
                (entry, score(queryTerms: named.isEmpty ? queryTerms : contentTerms, entry: entry), position)
            }
        return scored.filter { !named.isEmpty || $0.1 > 0 }
            .sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }
            .prefix(Self.resultLimit)
            .map {
                PrepMaterialSearchResult(
                    sourceDisplayName: $0.0.chunk.sourceDisplayName,
                    text: $0.0.chunk.text, documentID: $0.0.documentID)
            }
    }

    public func read(documentID: String, offset: Int) -> PrepMaterialPage? {
        guard offset >= 0, let document = documents.first(where: { $0.id == documentID }),
              offset < document.text.count else { return nil }
        let start = document.text.index(document.text.startIndex, offsetBy: offset)
        let end = document.text.index(start, offsetBy: 16_000, limitedBy: document.text.endIndex)
            ?? document.text.endIndex
        let text = String(document.text[start..<end])
        return PrepMaterialPage(sourceDisplayName: document.sourceDisplayName, text: text,
                                nextOffset: end == document.text.endIndex ? nil : offset + text.count)
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
