import AppKit
import JarvisCore

/// Settings panel for overlay appearance and the persistent response box. The overlay group has Text
/// Size and Background Opacity sliders (with a live sample while the tab is open); the response-box
/// group has its own Text Size and Opacity sliders that apply live to the box. All values persist
/// through `OverlayAppearance` and push to the live windows via the two `*Applying` protocols (no
/// direct panel dependency).
@MainActor
final class OverlaySection: NSObject, SettingsSection {
    let title = "Overlay"

    private let appearance: OverlayAppearance
    private let applying: OverlayAppearanceApplying
    private let responseBox: ResponseBoxAppearanceApplying
    private var sizeSlider: NSSlider?
    private var opacitySlider: NSSlider?
    private var sizeReadout: NSTextField?
    private var opacityReadout: NSTextField?
    private var boxSizeSlider: NSSlider?
    private var boxOpacitySlider: NSSlider?
    private var boxSizeReadout: NSTextField?
    private var boxOpacityReadout: NSTextField?

    init(appearance: OverlayAppearance, applying: OverlayAppearanceApplying,
         responseBox: ResponseBoxAppearanceApplying) {
        self.appearance = appearance
        self.applying = applying
        self.responseBox = responseBox
    }

    func makeView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 432))

        // MARK: Overlay group
        addHeader("Overlay", to: view, y: 400)

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

        // MARK: Response box group
        addHeader("Response Box", to: view, y: 212)

        let boxSizeLabel = NSTextField(labelWithString: "Text Size")
        boxSizeLabel.frame = NSRect(x: 24, y: 184, width: 200, height: 20)
        view.addSubview(boxSizeLabel)

        let boxSizeSlider = NSSlider(value: appearance.responseBoxFontSize,
                                     minValue: Config.responseBoxFontSizeRange.lowerBound,
                                     maxValue: Config.responseBoxFontSizeRange.upperBound,
                                     target: self, action: #selector(boxSizeChanged))
        boxSizeSlider.frame = NSRect(x: 24, y: 154, width: 440, height: 24)
        boxSizeSlider.setAccessibilityLabel("Response box text size")
        view.addSubview(boxSizeSlider)
        self.boxSizeSlider = boxSizeSlider

        let boxSizeReadout = NSTextField(labelWithString: "")
        boxSizeReadout.frame = NSRect(x: 472, y: 156, width: 64, height: 20)
        view.addSubview(boxSizeReadout)
        self.boxSizeReadout = boxSizeReadout

        let boxOpacityLabel = NSTextField(labelWithString: "Opacity")
        boxOpacityLabel.frame = NSRect(x: 24, y: 104, width: 200, height: 20)
        view.addSubview(boxOpacityLabel)

        let boxOpacitySlider = NSSlider(value: appearance.responseBoxOpacity,
                                        minValue: Config.responseBoxOpacityRange.lowerBound,
                                        maxValue: Config.responseBoxOpacityRange.upperBound,
                                        target: self, action: #selector(boxOpacityChanged))
        boxOpacitySlider.frame = NSRect(x: 24, y: 74, width: 440, height: 24)
        boxOpacitySlider.setAccessibilityLabel("Response box opacity")
        view.addSubview(boxOpacitySlider)
        self.boxOpacitySlider = boxOpacitySlider

        let boxOpacityReadout = NSTextField(labelWithString: "")
        boxOpacityReadout.frame = NSRect(x: 472, y: 76, width: 64, height: 20)
        view.addSubview(boxOpacityReadout)
        self.boxOpacityReadout = boxOpacityReadout

        updateReadouts()
        return view
    }

    /// A small bold section header.
    private func addHeader(_ text: String, to view: NSView, y: CGFloat) {
        let header = NSTextField(labelWithString: text)
        header.frame = NSRect(x: 24, y: y, width: 300, height: 20)
        header.font = .boldSystemFont(ofSize: 13)
        header.textColor = .secondaryLabelColor
        view.addSubview(header)
    }

    // Preview only while this tab is actually visible — not whenever the Settings window is open. Both
    // the overlay sample and the response box appear so their size/opacity sliders show live effect.
    func didBecomeActive() {
        applying.showAppearancePreview(true)
        responseBox.showAppearancePreview(true)
    }
    func didResignActive() {
        applying.showAppearancePreview(false)
        responseBox.showAppearancePreview(false)
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

    @objc private func boxSizeChanged(_ sender: NSSlider) {
        appearance.responseBoxFontSize = sender.doubleValue.rounded()
        sender.doubleValue = appearance.responseBoxFontSize
        responseBox.setBoxFontSize(appearance.responseBoxFontSize)
        updateReadouts()
    }

    @objc private func boxOpacityChanged(_ sender: NSSlider) {
        appearance.responseBoxOpacity = (sender.doubleValue * 100).rounded() / 100
        sender.doubleValue = appearance.responseBoxOpacity
        responseBox.setBoxOpacity(appearance.responseBoxOpacity)
        updateReadouts()
    }

    private func updateReadouts() {
        let pt = Int(appearance.fontSize.rounded())
        let pct = Int((appearance.backgroundOpacity * 100).rounded())
        sizeReadout?.stringValue = "\(pt) pt"
        opacityReadout?.stringValue = "\(pct)%"
        sizeSlider?.setAccessibilityValueDescription("\(pt) points")
        opacitySlider?.setAccessibilityValueDescription("\(pct) percent")

        let boxPt = Int(appearance.responseBoxFontSize.rounded())
        let boxPct = Int((appearance.responseBoxOpacity * 100).rounded())
        boxSizeReadout?.stringValue = "\(boxPt) pt"
        boxOpacityReadout?.stringValue = "\(boxPct)%"
        boxSizeSlider?.setAccessibilityValueDescription("\(boxPt) points")
        boxOpacitySlider?.setAccessibilityValueDescription("\(boxPct) percent")
    }
}
