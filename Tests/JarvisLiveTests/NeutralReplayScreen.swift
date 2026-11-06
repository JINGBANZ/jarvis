import Foundation
import JarvisCore
import AppKit

/// @unchecked: the generated JPEG is immutable.
final class NeutralReplayScreen: ScreenCapturing, @unchecked Sendable {
    private let image: String
    init() {
        // A neutral synthetic white viewport; text evidence is supplied separately by the normal screen port.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 3, bitsPerPixel: 24)!
        bitmap.setColor(.white, atX: 0, y: 0)
        image = bitmap.representation(using: .jpeg, properties: [:])!.base64EncodedString()
    }
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
        ScreenSnapshot(imageBase64: image)
    }
    func makeAttemptCapture() -> any ScreenCapturing { self }
    func cancelCapture() {}
}
