#if JARVIS_LIVE_E2E
import AppKit

@MainActor
final class CapturePrivacyMarkerView: NSView {
    static func attach(to window: NSWindow) throws {
        guard let content = window.contentView, content.bounds.width >= 120, content.bounds.height >= 88
        else { throw CocoaError(.coderInvalidValue) }
        let marker = CapturePrivacyMarkerView(frame: NSRect(x: 24, y: 24, width: 96, height: 64))
        content.addSubview(marker, positioned: .above, relativeTo: nil)
        marker.wantsLayer = true
        let colors = [(224, 23, 191), (47, 201, 123), (29, 36, 223)]
        for (index, color) in colors.enumerated() {
            let stripe = CALayer()
            stripe.backgroundColor = NSColor(srgbRed: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255,
                                             blue: CGFloat(color.2) / 255, alpha: 1).cgColor
            stripe.frame = NSRect(x: CGFloat(index) * 32, y: 0, width: 32, height: marker.bounds.height)
            marker.layer?.addSublayer(stripe)
        }
    }
}
#endif
