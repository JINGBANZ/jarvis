import Foundation

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
