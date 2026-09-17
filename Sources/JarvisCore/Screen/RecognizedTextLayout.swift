import Foundation

/// Accepted limit: side-by-side columns interleave line by line; the screenshot is ground truth.
public enum RecognizedTextLayout {
    /// Nil for no fragments, meaning no OCR is available.
    public static func orderedText(_ fragments: [TextFragment]) -> String? {
        guard !fragments.isEmpty else { return nil }
        var lines: [[TextFragment]] = []
        for fragment in fragments.sorted(by: { $0.minY < $1.minY }) {
            // Anchor on the line's first fragment, so drifting boxes can't smear two rows into one.
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
