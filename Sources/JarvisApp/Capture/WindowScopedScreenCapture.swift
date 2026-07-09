import Foundation
import CoreGraphics
import JarvisCore

/// Captures just the frontmost app window (`screencapture -l`) when the capture scope is
/// `.activeWindow`, with an on-device OCR of the shot riding along as `recognizedText`. Falls back
/// to the Settings-selected display (`ScreenCaptureCLI`) when the scope is `.entireDisplay`, no
/// eligible window is on screen, or the window capture fails — full-display fallbacks skip OCR
/// deliberately (a whole display's text would feed the clutter back as tokens).
///
/// Window choice reads the window server's single front-to-back z-order
/// (`CGWindowListCopyWindowInfo`), which spans all displays — so the pick is the window the user
/// last clicked or typed into, whichever monitor it is on. The selection rule itself is pure logic
/// in Core (`FrontWindowSelector`) where tests reach it; this type is only the CGWindowList dump
/// and the extra CLI flag. `-l` reads the window's own backing image, so the shot is clean even
/// when the window is partially covered; `-o` omits the window shadow.
struct WindowScopedScreenCapture: ScreenCapturing {
    private let preferences: ScreenCapturePreferences
    private let fallback: ScreenCaptureCLI
    private let recognizer = ScreenTextRecognizer()

    init(preferences: ScreenCapturePreferences) {
        self.preferences = preferences
        self.fallback = ScreenCaptureCLI(preferences: preferences)
    }

    func capture() -> ScreenSnapshot? {
        guard preferences.scope == .activeWindow,   // read at capture time, like the display index
              let windowID = Self.frontWindowID(),
              let jpeg = ScreenCaptureCLI.runScreencapture(
                  arguments: ["-x", "-o", "-t", "jpg", "-l", "\(windowID)"])
        else { return fallback.capture() }
        return ScreenSnapshot(imageBase64: jpeg.base64EncodedString(),
                              recognizedText: recognizer.recognizedText(inJPEG: jpeg))
    }

    /// Dumps the on-screen window list (front-to-back, all displays) into Core's selector.
    private static func frontWindowID() -> Int? {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let candidates = entries.compactMap { entry -> WindowCandidate? in
            guard let id = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int,
                  let layer = entry[kCGWindowLayer as String] as? Int
            else { return nil }
            let bounds = entry[kCGWindowBounds as String] as? [String: Double]
            return WindowCandidate(windowID: id, ownerPID: pid, layer: layer,
                                   width: bounds?["Width"] ?? 0, height: bounds?["Height"] ?? 0)
        }
        return FrontWindowSelector.frontWindowID(in: candidates,
                                                 ownPID: Int(ProcessInfo.processInfo.processIdentifier))
    }
}
