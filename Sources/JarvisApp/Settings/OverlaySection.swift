import AppKit
import JarvisCore

/// Settings panel for overlay appearance: Text Size and Background Opacity sliders with live
/// numeric readouts. Persists through `OverlayAppearance` and pushes live changes to the overlay via
/// `OverlayAppearanceApplying` (no direct OverlayPanel dependency). Shows a sample overlay while the
/// window is open so changes are visible, and clears it on close.
@MainActor
final class OverlaySection: NSObject, SettingsSection {
    let title = "Overlay"

    private let appearance: OverlayAppearance
    private let applying: OverlayAppearanceApplying
    private var sizeSlider: NSSlider?
    private var opacitySlider: NSSlider?
    private var sizeReadout: NSTextField?
    private var opacityReadout: NSTextField?

    init(appearance: OverlayAppearance, applying: OverlayAppearanceApplying) {
        self.appearance = appearance
        self.applying = applying
    }

    func makeView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 432))

        let sizeLabel = NSTextField(labelWithString: "Text Size")
        sizeLabel.frame = NSRect(x: 24, y: 372, width: 200, height: 20)
        view.addSubview(sizeLabel)

        let sizeSlider = NSSlider(value: appearance.fontSize,
                                  minValue: Config.overlayFontSizeRange.lowerBound,
                                  maxValue: Config.overlayFontSizeRange.upperBound,
                                  target: self, action: #selector(sizeChanged))
        sizeSlider.frame = NSRect(x: 24, y: 342, width: 440, height: 24)
        sizeSlider.setAccessibilityLabel("Text size")
        view.addSubview(sizeSlider)
        self.sizeSlider = sizeSlider

        let sizeReadout = NSTextField(labelWithString: "")
        sizeReadout.frame = NSRect(x: 472, y: 344, width: 64, height: 20)
        view.addSubview(sizeReadout)
        self.sizeReadout = sizeReadout

        let opacityLabel = NSTextField(labelWithString: "Background Opacity")
        opacityLabel.frame = NSRect(x: 24, y: 292, width: 200, height: 20)
        view.addSubview(opacityLabel)

        let opacitySlider = NSSlider(value: appearance.backgroundOpacity,
                                     minValue: Config.overlayOpacityRange.lowerBound,
                                     maxValue: Config.overlayOpacityRange.upperBound,
                                     target: self, action: #selector(opacityChanged))
        opacitySlider.frame = NSRect(x: 24, y: 262, width: 440, height: 24)
        opacitySlider.setAccessibilityLabel("Background opacity")
        view.addSubview(opacitySlider)
        self.opacitySlider = opacitySlider

        let opacityReadout = NSTextField(labelWithString: "")
        opacityReadout.frame = NSRect(x: 472, y: 264, width: 64, height: 20)
        view.addSubview(opacityReadout)
        self.opacityReadout = opacityReadout

        updateReadouts()
        applying.showAppearancePreview(true)   // live preview while the window is open
        return view
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        appearance.fontSize = sender.doubleValue.rounded()   // whole points: readout == stored == applied
        sender.doubleValue = appearance.fontSize             // snap the thumb to the rounded value
        applying.setFontSize(appearance.fontSize)
        updateReadouts()
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        appearance.backgroundOpacity = (sender.doubleValue * 100).rounded() / 100   // whole percent
        sender.doubleValue = appearance.backgroundOpacity    // snap the thumb to the rounded value
        applying.setBackgroundOpacity(appearance.backgroundOpacity)
        updateReadouts()
    }

    private func updateReadouts() {
        let pt = Int(appearance.fontSize.rounded())
        let pct = Int((appearance.backgroundOpacity * 100).rounded())
        sizeReadout?.stringValue = "\(pt) pt"
        opacityReadout?.stringValue = "\(pct)%"
        sizeSlider?.setAccessibilityValueDescription("\(pt) points")
        opacitySlider?.setAccessibilityValueDescription("\(pct) percent")
    }

    func windowWillClose() {
        applying.showAppearancePreview(false)
    }
}
