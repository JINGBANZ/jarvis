import AppKit

extension NSView {
    /// `color` as this view's appearance draws it, for layer properties that take a `CGColor`.
    /// `updateLayer()` already runs under the view's appearance; use this anywhere else.
    func themedCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}
