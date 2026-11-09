import AppKit
import JarvisCore
import JarvisOverlay
#if DEBUG
import JarvisTestDisplay
#endif

@MainActor
enum OverlayComposition {
    static func makeBox(contentSize: NSSize = NSSize(
        width: Defaults.Overlay.Box.width, height: Defaults.Overlay.Box.height)
    ) -> OverlayBoxPanel {
        #if DEBUG
        return OverlayBoxPanel(contentSize: contentSize, makePanel: { rect, style in
            TestDisplayPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        })
        #else
        return OverlayBoxPanel(contentSize: contentSize)
        #endif
    }
}
