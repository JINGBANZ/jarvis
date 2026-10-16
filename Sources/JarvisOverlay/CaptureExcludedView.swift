import AppKit

/// Popovers acquire their AppKit-owned window when their content view is attached.
public final class CaptureExcludedView: NSView {
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        newWindow?.excludeFromScreenCapture()
        super.viewWillMove(toWindow: newWindow)
    }
}
