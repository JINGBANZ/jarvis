import Foundation
import JarvisCore

/// A failed `-D` shot (e.g. the monitor was unplugged) retries on the main display, but a cleanup
/// failure never does. The overlay stays out of these shots through its own capture exclusion.
public struct ScreenCaptureCLI: ScreenCapturing {
    private let runner: ScreenCaptureRunner

    public init(runner: ScreenCaptureRunner) {
        self.runner = runner
    }

    public func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
        if let display = selection.explicitDisplay {
            switch runner.capture(arguments: ["-x", "-t", "jpg", "-D", "\(display)"]) {
            case let .captured(jpeg):
                return ScreenSnapshot(imageBase64: jpeg.base64EncodedString())
            case .cleanupFailed, .cancelled:
                return nil
            case .failed:
                break
            }
        }
        switch runner.capture(arguments: ["-x", "-t", "jpg"]) {
        case let .captured(jpeg):
            return ScreenSnapshot(imageBase64: jpeg.base64EncodedString())
        case .failed, .cleanupFailed, .cancelled:
            return nil
        }
    }

    public func cancelCapture() {
        runner.cancelCapture()
    }
}
