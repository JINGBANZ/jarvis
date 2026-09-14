import Foundation

public let captureScreenTool = ToolDef(
    name: "capture_screen",
    description: "Capture a fresh screenshot plus available text evidence from the foreground "
        + "context. Use when the next useful response depends on current screen information not "
        + "already available; one fresh result satisfies that request.",
    parametersJSON: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#,
    guidance: """
        # Screen evidence
        A capture returns a screenshot plus any labeled text sources available for the same window.
        Chrome Accessibility text can include content outside the viewport, but it may omit canvas,
        images, diagrams, lazy content, and parts of virtualized editors. OCR covers only visible
        pixels and may misread tokens. Use both sources together. Treat screenshot as ground truth
        for visible layout, pictures, diagrams, and exact-token claims. Before asserting a
        visible line or token is wrong, verify it in the image. If it appears only in text evidence,
        frame the tip as something to double-check instead of declaring a defect.
        """
)

// What the harness tells the model about a capture: the tool result, the observation that carries
// the screenshot, and the stubs that replace both in later history.
extension JarvisPrompts.Coach {
    static let captureSucceeded = "screenshot captured"
    static let captureFailed = "screenshot failed"

    static func captureResult(textEvidence: [ScreenTextEvidence]) -> String {
        guard !textEvidence.isEmpty else { return captureSucceeded }
        return "\(captureSucceeded)\n\n\(screenText(textEvidence))"
    }

    static let screenTextHeader = "Captured screen text evidence"

    static func screenText(_ evidence: [ScreenTextEvidence]) -> String {
        evidence.map { item in
            let source = item.source == .browserAccessibility
                ? "Chrome Accessibility (active-tab tree, may include off-screen text)"
                : "On-device OCR (current screenshot viewport)"
            let omission = item.truncated ? " — truncated" : ""
            return "\(screenTextHeader) — \(source)\(omission):\n\(item.text)"
        }.joined(separator: "\n\n")
    }

    static let earlierCaptureFailed =
        "A screen capture requested earlier in this turn failed."
    static let manualHintCaptureFailed =
        "The screen capture requested for the shortcut failed. Use available conversation context; do not guess unseen details."

    // Keep this a neutral marker. An earlier instruction to recapture, repeated in user-role
    // history, biased the coach toward capturing on every quiet turn.
    static let earlierImageStub = "[an earlier screenshot was here — no longer available]"
    static let supersededScreenTextStub =
        "[an earlier screen's text evidence was here — superseded by a newer capture]"
}
