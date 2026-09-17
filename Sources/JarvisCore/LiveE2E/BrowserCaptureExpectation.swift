#if JARVIS_LIVE_E2E
import Foundation

/// Exact, operator-supplied expectations for one production Chrome capture. This check does not
/// infer file completeness or combine observations from different file versions.
public struct BrowserCaptureExpectation: Decodable, Sendable {
    public let requiredText: [String]
    public let forbiddenText: [String]

    public static func decode(_ data: Data) throws -> Self {
        let expectation = try JSONDecoder().decode(Self.self, from: data)
        guard !expectation.requiredText.isEmpty,
              expectation.requiredText.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              expectation.forbiddenText.allSatisfy({ !$0.isEmpty }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return expectation
    }

    public func failures(in snapshot: ScreenSnapshot?) -> [String] {
        guard let snapshot else { return ["No screen capture was returned."] }
        let accessibility = snapshot.textEvidence.filter {
            $0.source == .browserAccessibility && $0.coverage == .activeTabAccessibilityTree
        }
        guard !accessibility.isEmpty else { return ["No Chrome accessibility text was returned; OCR is insufficient."] }
        var failures: [String] = []
        if accessibility.contains(where: \.truncated) {
            failures.append("Chrome accessibility text was truncated.")
        }
        for (index, expected) in requiredText.enumerated() {
            if !accessibility.contains(where: { $0.text.contains(expected) }) {
                failures.append("Required text block \(index + 1) was not captured exactly.")
            }
        }
        for (index, forbidden) in forbiddenText.enumerated() {
            if snapshot.textEvidence.contains(where: { $0.text.contains(forbidden) }) {
                failures.append("Excluded text block \(index + 1) appeared in the capture.")
            }
        }
        return failures
    }
}
#endif
