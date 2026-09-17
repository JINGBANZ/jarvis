import AppKit

extension NSView {
    /// Text placed between pixels gets snapped by AppKit, which can push it a pixel off center on a
    /// 1x display, so a position that must be centered is rounded to the screen's own pixel grid.
    func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }
}
