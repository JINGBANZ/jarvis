import AppKit

extension NSView {
    /// For layer colors set outside `updateLayer()`, which already runs under the view's appearance.
    func themedCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}
