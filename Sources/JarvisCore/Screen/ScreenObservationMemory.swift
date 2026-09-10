import Foundation

/// Exact, partial observations, not a reconstructed document. Confined to the runner's single-flight
/// attempt lane; never read by background history compaction and never persisted separately.
struct ScreenObservationMemory {
    struct Observation: Encodable, Equatable {
        let id: Int
        let sourceID: String?
        let elapsedSeconds: Int
        let text: String
        let truncated: Bool
    }

    private let byteLimit: Int
    private let observationLimit: Int
    private(set) var observations: [Observation] = []
    private(set) var latestID = 0
    private(set) var hasOmissions = false
    private var lastEvictedID = 0

    init(byteLimit: Int = 32_768, observationLimit: Int = 32) {
        self.byteLimit = max(0, byteLimit)
        self.observationLimit = max(0, observationLimit)
    }

    @discardableResult
    mutating func record(text: String, sourceID: String?, elapsedSeconds: TimeInterval) -> Int? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        latestID += 1
        // A partial copy is explicitly marked. UTF-8 clipping never manufactures a broken scalar.
        let bounded = Self.prefix(text, bytes: byteLimit)
        let source = sourceID.flatMap { $0.utf8.count <= 128 ? $0 : nil }
        let truncated = bounded.utf8.count < text.utf8.count
        if truncated { hasOmissions = true }
        if let source, !truncated {
            // A window is only provenance, not a filename. Never infer edits/overlap from its ID.
            observations.removeAll { $0.sourceID == source && !$0.truncated && $0.text == text }
        }
        let seconds = elapsedSeconds.isFinite ? Int(min(max(0, elapsedSeconds), 1_000_000_000)) : 0
        observations.append(Observation(id: latestID, sourceID: source, elapsedSeconds: seconds,
                                        text: bounded, truncated: truncated))
        while observations.count > observationLimit
            || observations.reduce(0, { $0 + $1.text.utf8.count }) > byteLimit
            || observations.first?.text.isEmpty == true {
            lastEvictedID = observations.removeFirst().id
            hasOmissions = true
        }
        return latestID
    }

    mutating func apply(_ update: ScreenMemoryUpdate, after boundary: Int, visibleIDs: Set<Int>, keepingIDs: Set<Int> = []) {
        if update.newQuestion {
            observations.removeAll { $0.id <= boundary && !keepingIDs.contains($0.id) }
            // Reset only omissions from the old question. A whole current fragment may have
            // been evicted even when every surviving observation is individually untruncated.
            hasOmissions = lastEvictedID > boundary
                || keepingIDs.contains(where: { $0 <= lastEvictedID })
                || observations.contains(where: \.truncated)
        }
        let obsolete = Set(update.obsoleteObservationIDs).intersection(visibleIDs)
        observations.removeAll { obsolete.contains($0.id) }
    }

    func contextMessage(excludingID currentID: Int? = nil) -> ChatMessage? {
        // Only this observation is already in the current screen slot. Equal text from another
        // capture must retain its identity and provenance for interpretation and retirement.
        let historical = observations.filter { $0.id != currentID }
        guard !historical.isEmpty || hasOmissions else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // These values are only strings, integers and booleans: encoding cannot fail.
        let data = try! encoder.encode(historical)
        return .user(JarvisPrompts.ScreenMemory.context(
            json: String(decoding: data, as: UTF8.self), hasOmissions: hasOmissions))
    }

    private static func prefix(_ text: String, bytes limit: Int) -> String {
        var bytes = 0
        var end = text.unicodeScalars.startIndex
        for scalar in text.unicodeScalars {
            let size = scalar.utf8.count
            guard bytes + size <= limit else { break }
            bytes += size
            end = text.unicodeScalars.index(after: end)
        }
        return String(text[..<end])
    }
}
