import Foundation

/// What the overlay needs to do; the real NSPanel impl lives in JarvisOverlay.
public protocol OverlayRendering: AnyObject {
    /// Render `lines` one at a time, each shown for `perLineSeconds`. The brain returns the lines
    /// already split (the `speak` tool's `lines` array), so there is no client-side sentence splitting.
    func render(_ lines: [String], perLineSeconds: TimeInterval)
}
