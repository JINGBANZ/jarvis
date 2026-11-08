import AppKit

@MainActor
final class OverlayBoxWindow: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        OverlayTestDisplay.constrainedFrame(frameRect) ?? super.constrainFrameRect(frameRect, to: screen)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        super.setFrame(OverlayTestDisplay.constrainedFrame(frameRect) ?? frameRect,
                       display: flag, animate: animate)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(OverlayTestDisplay.constrainedFrame(frameRect) ?? frameRect, display: flag)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        let proposed = NSRect(origin: point, size: frame.size)
        super.setFrameOrigin(OverlayTestDisplay.constrainedFrame(proposed)?.origin ?? point)
    }
}
