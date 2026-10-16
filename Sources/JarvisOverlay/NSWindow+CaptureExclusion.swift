import AppKit

// Design: wiki/overlay-invisibility.md
extension NSWindow {
    private static let captureExcludedWindows = NSHashTable<NSWindow>.weakObjects()

    public func excludeFromScreenCapture() {
        Self.captureExcludedWindows.add(self)
        sharingType = .none
    }

    /// An activation-policy change can reset WindowServer's sharing state, including on idle windows.
    public static func reassertCaptureExclusion() {
        for window in captureExcludedWindows.allObjects {
            window.sharingType = .none
        }
    }
}
