import Foundation

/// The browser-owned chrome above a Chromium page: tab strip + address/toolbar rows. Keeping this
/// decision in Core makes the bundle allowlist and point-to-pixel conversion testable; the actual
/// JPEG crop stays at the CoreGraphics edge in JarvisApp.
public enum BrowserChromeCrop {
    /// Chrome's standard macOS tab strip and toolbar occupy 82 points.
    /// Other browsers have user-selectable toolbar layouts, so leave them untouched until each has
    /// a reliable content boundary of its own.
    private static let topInsetPoints = 82.0

    private static let supportedBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.google.Chrome.forTesting",
        "org.chromium.Chromium",
    ]

    /// Returns the number of top pixel rows to remove, or nil when the selected window should be
    /// captured unchanged. `windowWidthPoints` comes from CGWindowList; comparing it with the JPEG
    /// width preserves the same physical inset for 1x and Retina backing images.
    public static func topInsetPixels(bundleIdentifier: String?,
                                      imageWidth: Int,
                                      imageHeight: Int,
                                      windowWidthPoints: Double) -> Int? {
        guard let bundleIdentifier,
              supportedBundleIdentifiers.contains(bundleIdentifier),
              imageWidth > 0,
              imageHeight > 0,
              windowWidthPoints > 0
        else { return nil }

        let backingScale = Double(imageWidth) / windowWidthPoints
        let inset = Int((topInsetPoints * backingScale).rounded())
        guard inset > 0, inset < imageHeight else { return nil }
        return inset
    }
}
