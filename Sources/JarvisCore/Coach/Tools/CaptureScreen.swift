import Foundation

public let captureScreenTool = ToolDef(
    name: "capture_screen",
    description: "Inspect the current foreground screen. Returns a fresh JPEG screenshot plus available, "
        + "timestamped OCR or Accessibility text.",
    parametersJSON: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#,
    guidance: """
        # When to capture
        Capture before replying when a specific, correct answer depends on current visible information
        missing from the conversation. This includes an explicit request to look or an unresolved reference
        such as "this question", "here", or "my code" without enough content to answer. Either speaker can
        establish the missing visual context. A fresh screenshot or screen text already in the current request satisfies the need;
        use it instead of capturing again for the same request.

        # Interpreting screen evidence
        Each text source's label states its capture time and limitations.
        The screenshot is ground truth for layout, pictures, diagrams, and exact visible tokens.
        Before saying a visible line or token is wrong, check it in the image. If it appears only in the
        text, suggest double-checking it instead. Do not infer content outside the capture.
        """
)

extension JarvisPrompts.Coach {
    static let captureSucceeded = "screenshot captured"
    static let captureFailed = "screenshot failed"

    static func captureResult(textEvidence: [ScreenTextEvidence], capturedAt: String) -> String {
        guard !textEvidence.isEmpty else { return captureSucceeded }
        return "\(captureSucceeded)\n\n\(screenText(textEvidence, capturedAt: capturedAt))"
    }

    static let screenTextHeader = "Captured screen text evidence"

    /// Keep both the stamp and "may have changed since": with the stamp alone, old text still
    /// passed the screen gate in live runs and the model skipped a fresh capture.
    static func screenText(_ evidence: [ScreenTextEvidence], capturedAt: String) -> String {
        evidence.map { item in
            let source = item.source == .browserAccessibility
                ? "Chrome Accessibility (captured at [\(capturedAt)], active-tab tree; the screen "
                    + "may have changed since; may include off-screen text; may miss canvas, "
                    + "images, diagrams, lazy content, and parts of virtualized editors)"
                : "On-device OCR (captured at [\(capturedAt)], screenshot viewport; the screen may "
                    + "have changed since; may misread tokens)"
            let omission = item.truncated ? " — truncated" : ""
            return "\(screenTextHeader) — \(source)\(omission):\n\(item.text)"
        }.joined(separator: "\n\n")
    }

    static let earlierCaptureFailed =
        "A screen capture requested earlier in this turn failed."
    static let manualHintCaptureFailed =
        "The screen capture requested for the shortcut failed. Use available conversation context; do not guess unseen details."

    // Keep neutral: a recapture instruction here made the coach capture on every quiet turn.
    static let earlierImageStub = "[an earlier screenshot was here — no longer available]"
    static let supersededScreenTextStub =
        "[an earlier screen's text evidence was here — superseded by a newer capture]"
}
