import AppKit

// Design: wiki/overlay-invisibility.md
extension NSPanel {
    /// Callers re-assert this on every show: an activation-policy flip can make WindowServer drop
    /// `sharingType` on some macOS builds.
    func excludeFromScreenCapture() {
        sharingType = .none
    }
}
