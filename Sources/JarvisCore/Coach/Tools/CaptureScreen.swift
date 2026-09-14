import Foundation

public let captureScreenTool = ToolDef(
    name: "capture_screen",
    description: "Capture a fresh screenshot plus available text evidence from the foreground "
        + "context. Use when the next useful response depends on current screen information not "
        + "already available; one fresh result satisfies that request.",
    parametersJSON: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#
)

// What the harness tells the model about a capture: the tool result, the observation that carries
// the screenshot, and the stubs that replace both in later history.
extension JarvisPrompts.Coach {
    static let captureSucceeded = "screenshot captured"
    static let captureFailed = "screenshot failed"

    static func captureResult(textEvidence: ScreenTextEvidence?) -> String {
        guard let textEvidence else { return captureSucceeded }
        return "\(captureSucceeded)\n\n\(screenText(textEvidence))"
    }

    static let screenTextHeader = "Captured screen text evidence:"

    static func screenText(_ evidence: ScreenTextEvidence) -> String {
        let description: String
        switch evidence.source {
        case .browserAccessibility:
            description = "Chrome Accessibility tree for the active tab — may include off-screen "
                + "text, but may omit lazy, virtualized, canvas, image, or hidden content; this is "
                + "not guaranteed complete HTML or a complete editor buffer"
        case .onDeviceOCR:
            description = "on-device OCR of the current screenshot viewport — may contain errors; "
                + "the screenshot image is ground truth"
        }
        let omission = evidence.truncated ? "; source text was truncated by the capture limit" : ""
        return "\(screenTextHeader)\nSource: \(description)\(omission).\n\(evidence.text)"
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
