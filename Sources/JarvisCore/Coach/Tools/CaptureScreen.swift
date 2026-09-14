import Foundation

public let captureScreenTool = ToolDef(
    name: "capture_screen",
    description: "Capture a fresh screenshot and OCR of visible interview "
        + "context. Use when the next useful response depends on current screen information "
        + "not already available; one fresh result satisfies that request.",
    parametersJSON: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#
)

// What the harness tells the model about a capture: the tool result, the observation that carries
// the screenshot, and the stubs that replace both in later history.
extension JarvisPrompts.Coach {
    static let captureSucceeded = "screenshot captured"
    static let captureFailed = "screenshot failed"

    static func captureResult(recognizedText text: String?) -> String {
        guard let text else { return captureSucceeded }
        return "\(captureSucceeded)\n\n\(recognizedText(text))"
    }

    static let recognizedTextHeader =
        "Text recognized on the captured window (on-device OCR — may contain "
        + "errors; the screenshot image is ground truth):"

    static func recognizedText(_ text: String) -> String {
        "\(recognizedTextHeader)\n\(text)"
    }

    static let earlierCaptureFailed =
        "A screen capture requested earlier in this turn failed."
    static let manualHintCaptureFailed =
        "The screen capture requested for the shortcut failed. Use available conversation context; do not guess unseen details."

    // Keep this a neutral marker. An earlier instruction to recapture, repeated in user-role
    // history, biased the coach toward capturing on every quiet turn.
    static let earlierImageStub = "[an earlier screenshot was here — no longer available]"
    static let supersededRecognizedTextStub =
        "[an earlier screen's OCR text was here — superseded by a newer capture]"
}
