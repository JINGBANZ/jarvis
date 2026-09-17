import Foundation
import CoreGraphics
import JarvisCore
import JarvisScreenCapture

/// `screencapture -l` reads the window's own backing image, so the shot is clean even when the
/// window is partly covered; `-o` omits the shadow.
struct WindowScopedScreenCapture: ScreenCapturing {
    private let runner: ScreenCaptureRunner
    private let fallback: ScreenCaptureCLI
    private let textResolver = ScreenTextResolver(
        browser: BrowserAccessibilityReader(),
        ocr: ScreenTextRecognizer())

    init(captureDirectory: URL) {
        let runner = ScreenCaptureRunner(captureDirectory: captureDirectory)
        self.runner = runner
        self.fallback = ScreenCaptureCLI(runner: runner)
    }

    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
        if selection.scope == .activeWindow,
           let window = Self.frontWindow() {
            // Read the page identity before capturing: browser text is accepted only while this
            // document stays active, so a tab switch cannot pair new text with old pixels.
            let browserDocumentIdentity = selection.browserTextEnabled
                ? textResolver.browserDocumentIdentity(for: window)
                : nil
            guard !Task.isCancelled else { return nil }
            let outcome = runner.capture(
                arguments: ["-x", "-o", "-t", "jpg", "-l", "\(window.windowID)"])
            switch outcome {
            case let .captured(jpeg):
                return ScreenSnapshot(
                    imageBase64: jpeg.base64EncodedString(),
                    textEvidence: textResolver.resolve(
                        jpeg: jpeg,
                        window: window,
                        browserDocumentIdentity: browserDocumentIdentity))
            case .cleanupFailed, .cancelled:
                return nil
            case .failed:
                break
            }
        }
        return fallback.capture(selection)
    }

    func cancelCapture() {
        runner.cancelCapture()
    }

    private static func frontWindow() -> WindowCandidate? {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let candidates = entries.compactMap { entry -> WindowCandidate? in
            guard let id = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int,
                  let layer = entry[kCGWindowLayer as String] as? Int
            else { return nil }
            let bounds = entry[kCGWindowBounds as String] as? [String: Double]
            return WindowCandidate(
                windowID: id,
                ownerPID: pid,
                layer: layer,
                x: bounds?["X"] ?? 0,
                y: bounds?["Y"] ?? 0,
                width: bounds?["Width"] ?? 0,
                height: bounds?["Height"] ?? 0)
        }
        return FrontWindowSelector.frontWindow(
            in: candidates,
            ownPID: Int(ProcessInfo.processInfo.processIdentifier))
    }
}
