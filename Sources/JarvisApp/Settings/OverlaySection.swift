import AppKit
import JarvisCore

/// Settings panel for the two overlay surfaces. Each group — Overlay Caption (the transient on-screen
/// tip) and Overlay Box (the persistent response history) — has an on/off checkbox, a one-line
/// description, and Text Size + Opacity sliders that apply live (with a sample shown while the tab is
/// open). All values persist through `OverlayAppearance` and push to the live windows via the two
/// `*Applying` protocols (no direct panel dependency).
@MainActor
final class OverlaySection: NSObject, SettingsSection {
    let title = "Overlay"

    private let appearance: OverlayAppearance
    private let caption: OverlayCaptionApplying
    private let box: OverlayBoxApplying
    private var captionSizeSlider: NSSlider?
    private var captionOpacitySlider: NSSlider?
    private var captionSizeReadout: NSTextField?
    private var captionOpacityReadout: NSTextField?
    private var boxSizeSlider: NSSlider?
    private var boxOpacitySlider: NSSlider?
    private var boxSizeReadout: NSTextField?
    private var boxOpacityReadout: NSTextField?

    init(appearance: OverlayAppearance, caption: OverlayCaptionApplying, box: OverlayBoxApplying) {
        self.appearance = appearance
        self.caption = caption
        self.box = box
    }

    // Layout constants. AppKit's origin is bottom-left, so a running `cursor` decrements from the top.
    private enum L {
        static let width: CGFloat = 560
        static let left: CGFloat = 24
        static let sliderWidth: CGFloat = 440
        static let readoutX: CGFloat = 472
        static let readoutWidth: CGFloat = 64
        static let checkboxX: CGFloat = 300
        static let checkboxWidth: CGFloat = 236
    }

    func makeView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: L.width, height: 432))
        var cursor: CGFloat = 416   // top edge, leaving a 16pt top margin

        let cap = addGroup(
            to: view, cursor: &cursor,
            header: "Overlay Caption", description: "A transient response from Jarvis.",
            enabledOn: appearance.captionEnabled, enableAction: #selector(captionEnabledChanged),
            sizeValue: appearance.captionFontSize, sizeRange: Config.overlayCaptionFontSizeRange,
            sizeAction: #selector(captionSizeChanged), sizeA11y: "Overlay caption text size",
            opacityTitle: "Background Opacity", opacityValue: appearance.captionBackgroundOpacity,
            opacityRange: Config.overlayCaptionOpacityRange, opacityAction: #selector(captionOpacityChanged),
            opacityA11y: "Overlay caption background opacity")
        captionSizeSlider = cap.sizeSlider
        captionSizeReadout = cap.sizeReadout
        captionOpacitySlider = cap.opacitySlider
        captionOpacityReadout = cap.opacityReadout

        cursor -= 24   // gap between the two groups

        let bx = addGroup(
            to: view, cursor: &cursor,
            header: "Overlay Box", description: "A persistent history of messages from Jarvis.",
            enabledOn: appearance.boxEnabled, enableAction: #selector(boxEnabledChanged),
            sizeValue: appearance.boxFontSize, sizeRange: Config.overlayBoxFontSizeRange,
            sizeAction: #selector(boxSizeChanged), sizeA11y: "Overlay box text size",
            opacityTitle: "Opacity", opacityValue: appearance.boxOpacity,
            opacityRange: Config.overlayBoxOpacityRange, opacityAction: #selector(boxOpacityChanged),
            opacityA11y: "Overlay box opacity")
        boxSizeSlider = bx.sizeSlider
        boxSizeReadout = bx.sizeReadout
        boxOpacitySlider = bx.opacitySlider
        boxOpacityReadout = bx.opacityReadout

        updateReadouts()
        return view
    }

    /// Build one appearance group — bold header + enable checkbox on one row, a description line, then
    /// Text Size and Opacity sliders with readouts — placing each control under the running `cursor`.
    private func addGroup(
        to view: NSView, cursor: inout CGFloat,
        header: String, description: String,
        enabledOn: Bool, enableAction: Selector,
        sizeValue: Double, sizeRange: ClosedRange<Double>, sizeAction: Selector, sizeA11y: String,
        opacityTitle: String, opacityValue: Double, opacityRange: ClosedRange<Double>,
        opacityAction: Selector, opacityA11y: String
    ) -> (sizeSlider: NSSlider, sizeReadout: NSTextField, opacitySlider: NSSlider, opacityReadout: NSTextField) {
        // Header + enable checkbox on the same row.
        cursor -= 20
        let headerLabel = NSTextField(labelWithString: header)
        headerLabel.frame = NSRect(x: L.left, y: cursor, width: 220, height: 20)
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.textColor = .secondaryLabelColor
        view.addSubview(headerLabel)

        let enable = NSButton(checkboxWithTitle: enableActionTitle(header), target: self, action: enableAction)
        enable.state = enabledOn ? .on : .off
        enable.frame = NSRect(x: L.checkboxX, y: cursor, width: L.checkboxWidth, height: 20)
        view.addSubview(enable)

        // Description line.
        cursor -= 4
        cursor -= 16
        let desc = NSTextField(labelWithString: description)
        desc.frame = NSRect(x: L.left, y: cursor, width: L.width - 2 * L.left, height: 16)
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .tertiaryLabelColor
        view.addSubview(desc)

        // Text Size.
        cursor -= 12
        let (sizeSlider, sizeReadout) = addSliderRow(
            to: view, cursor: &cursor, label: "Text Size", value: sizeValue, range: sizeRange,
            action: sizeAction, a11y: sizeA11y)

        // Opacity.
        cursor -= 12
        let (opacitySlider, opacityReadout) = addSliderRow(
            to: view, cursor: &cursor, label: opacityTitle, value: opacityValue, range: opacityRange,
            action: opacityAction, a11y: opacityA11y)

        return (sizeSlider, sizeReadout, opacitySlider, opacityReadout)
    }

    /// A labelled slider with a right-hand readout, placed under the running cursor.
    private func addSliderRow(
        to view: NSView, cursor: inout CGFloat, label: String, value: Double,
        range: ClosedRange<Double>, action: Selector, a11y: String
    ) -> (slider: NSSlider, readout: NSTextField) {
        cursor -= 20
        let labelField = NSTextField(labelWithString: label)
        labelField.frame = NSRect(x: L.left, y: cursor, width: 200, height: 20)
        view.addSubview(labelField)

        cursor -= 6
        cursor -= 24
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: self, action: action)
        slider.frame = NSRect(x: L.left, y: cursor, width: L.sliderWidth, height: 24)
        slider.setAccessibilityLabel(a11y)
        view.addSubview(slider)

        let readout = NSTextField(labelWithString: "")
        readout.frame = NSRect(x: L.readoutX, y: cursor + 2, width: L.readoutWidth, height: 20)
        view.addSubview(readout)

        return (slider, readout)
    }

    private func enableActionTitle(_ header: String) -> String {
        "Show \(header.lowercased())"
    }

    // Preview only while this tab is actually visible — not whenever the Settings window is open. Both
    // surfaces appear (regardless of their on/off state) so their size/opacity sliders show live effect.
    func didBecomeActive() {
        caption.showAppearancePreview(true)
        box.showAppearancePreview(true)
    }
    func didResignActive() {
        caption.showAppearancePreview(false)
        box.showAppearancePreview(false)
    }

    // MARK: - Enable toggles

    @objc private func captionEnabledChanged(_ sender: NSButton) {
        let on = sender.state == .on
        appearance.captionEnabled = on
        caption.setEnabled(on)
    }

    @objc private func boxEnabledChanged(_ sender: NSButton) {
        let on = sender.state == .on
        appearance.boxEnabled = on
        box.setEnabled(on)
    }

    // MARK: - Appearance sliders

    @objc private func captionSizeChanged(_ sender: NSSlider) {
        appearance.captionFontSize = sender.doubleValue.rounded()   // whole points: readout == stored == applied
        sender.doubleValue = appearance.captionFontSize             // snap the thumb to the rounded value
        caption.setFontSize(appearance.captionFontSize)
        updateReadouts()
    }

    @objc private func captionOpacityChanged(_ sender: NSSlider) {
        appearance.captionBackgroundOpacity = (sender.doubleValue * 100).rounded() / 100   // whole percent
        sender.doubleValue = appearance.captionBackgroundOpacity    // snap the thumb to the rounded value
        caption.setBackgroundOpacity(appearance.captionBackgroundOpacity)
        updateReadouts()
    }

    @objc private func boxSizeChanged(_ sender: NSSlider) {
        appearance.boxFontSize = sender.doubleValue.rounded()
        sender.doubleValue = appearance.boxFontSize
        box.setFontSize(appearance.boxFontSize)
        updateReadouts()
    }

    @objc private func boxOpacityChanged(_ sender: NSSlider) {
        appearance.boxOpacity = (sender.doubleValue * 100).rounded() / 100
        sender.doubleValue = appearance.boxOpacity
        box.setOpacity(appearance.boxOpacity)
        updateReadouts()
    }

    private func updateReadouts() {
        let capPt = Int(appearance.captionFontSize.rounded())
        let capPct = Int((appearance.captionBackgroundOpacity * 100).rounded())
        captionSizeReadout?.stringValue = "\(capPt) pt"
        captionOpacityReadout?.stringValue = "\(capPct)%"
        captionSizeSlider?.setAccessibilityValueDescription("\(capPt) points")
        captionOpacitySlider?.setAccessibilityValueDescription("\(capPct) percent")

        let boxPt = Int(appearance.boxFontSize.rounded())
        let boxPct = Int((appearance.boxOpacity * 100).rounded())
        boxSizeReadout?.stringValue = "\(boxPt) pt"
        boxOpacityReadout?.stringValue = "\(boxPct)%"
        boxSizeSlider?.setAccessibilityValueDescription("\(boxPt) points")
        boxOpacitySlider?.setAccessibilityValueDescription("\(boxPct) percent")
    }
}
