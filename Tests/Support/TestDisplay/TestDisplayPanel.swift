#if DEBUG
import AppKit

@MainActor
public final class TestDisplayPanel: NSPanel {
    private var placement: OverlayTestDisplay?

    public override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                         backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        placement = OverlayTestDisplay(window: self)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    public override func center() {
        if let placement { placement.position() } else { super.center() }
    }

    public override func orderFrontRegardless() {
        placement?.position()
        super.orderFrontRegardless() // ghost-mode-allowed: isolated test overlay or capture fixture
        placement?.verifyVisiblePlacement()
    }

    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        OverlayTestDisplay.constrainedFrame(frameRect) ?? super.constrainFrameRect(frameRect, to: screen)
    }

    public override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        super.setFrame(OverlayTestDisplay.constrainedFrame(frameRect) ?? frameRect,
                       display: flag, animate: animate)
    }

    public override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(OverlayTestDisplay.constrainedFrame(frameRect) ?? frameRect, display: flag)
    }

    public override func setFrameOrigin(_ point: NSPoint) {
        let proposed = NSRect(origin: point, size: frame.size)
        super.setFrameOrigin(OverlayTestDisplay.constrainedFrame(proposed)?.origin ?? point)
    }
}
#endif
