import Foundation

/// One OCR'd run of text and its normalized bounding box, top-left origin (y grows downward, so
/// smaller `minY` = higher on screen). The Vision edge in JarvisApp flips from Vision's
/// bottom-left origin before handing fragments over.
public struct TextFragment: Sendable, Equatable {
    public let string: String
    public let minX: Double
    public let minY: Double
    public let width: Double
    public let height: Double

    public init(string: String, minX: Double, minY: Double, width: Double, height: Double) {
        self.string = string
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }
}

/// Reconstructs reading order from per-line OCR fragments: top-to-bottom, fragments whose boxes
/// overlap vertically (by at least half the shorter box) share one output line, ordered
/// left-to-right within it.
///
/// Known limit, accepted deliberately: side-by-side page columns interleave line-by-line. Each
/// fragment stays intact and the screenshot rides along as ground truth, so the brain can
/// disentangle; if the PoC shows it matters, the contained fix is clustering fragments into
/// columns by x-gap before sorting (still pure geometry, still testable here).
public enum RecognizedTextLayout {
    /// Nil for no fragments, so callers can treat "no text recognized" as "no OCR available".
    public static func orderedText(_ fragments: [TextFragment]) -> String? {
        guard !fragments.isEmpty else { return nil }
        var lines: [[TextFragment]] = []
        for fragment in fragments.sorted(by: { $0.minY < $1.minY }) {
            // Compare against the current line's FIRST fragment: it anchors the line's vertical
            // band, so a chain of slightly-drifting boxes can't smear two rows into one.
            if let anchor = lines.last?.first, sameLine(anchor, fragment) {
                lines[lines.count - 1].append(fragment)
            } else {
                lines.append([fragment])
            }
        }
        return lines
            .map { line in
                line.sorted { $0.minX < $1.minX }.map(\.string).joined(separator: "   ")
            }
            .joined(separator: "\n")
    }

    private static func sameLine(_ a: TextFragment, _ b: TextFragment) -> Bool {
        let overlap = min(a.minY + a.height, b.minY + b.height) - max(a.minY, b.minY)
        return overlap >= 0.5 * min(a.height, b.height)
    }
}
