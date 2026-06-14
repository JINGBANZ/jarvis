import Foundation

/// What the overlay needs to do; the real NSPanel impl lives in JarvisApp.
public protocol OverlayRendering: AnyObject {
    /// Render up to `maxSentences`, each shown for `perSentenceSeconds`.
    func render(_ text: String, maxSentences: Int, perSentenceSeconds: TimeInterval)
}

/// Split text into sentences on . ! ? boundaries, trim, drop empties, cap at maxSentences.
public func splitIntoSentences(_ text: String, maxSentences: Int) -> [String] {
    var sentences: [String] = []
    var current = ""
    for ch in text {
        current.append(ch)
        if ch == "." || ch == "!" || ch == "?" {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
        }
    }
    let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { sentences.append(tail) }
    return Array(sentences.prefix(maxSentences))
}
