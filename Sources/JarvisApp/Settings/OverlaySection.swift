import AppKit
import JarvisCore

/// Settings panel for the two overlay surfaces. Each group — Overlay Caption (the transient on-screen
/// tip) and Overlay Box (the persistent response history) — has a header with an On/Off toggle and a
/// one-line description. When a surface is **on** it also shows its Text Size + Opacity sliders and a
/// live sample (while the tab is open); when **off**, both its configuration and its preview are
/// hidden, and the layout collapses so the other group moves up. All values persist through
/// `OverlayAppearance` and push to the live windows via the two `*Applying` protocols.
@MainActor
final class OverlaySection: NSObject, SettingsSection {
    let title = "Overlay"

    private let appearance: OverlayAppearance
    private let caption: OverlayCaptionApplying
    private let box: OverlayBoxApplying

    // Built once per `makeView`, then repositioned by `relayout()` as toggles flip.
    private weak var rootView: NSView?
    private var captionViews: SurfaceViews?
    private var boxViews: SurfaceViews?

    init(appearance: OverlayAppearance, caption: OverlayCaptionApplying, box: OverlayBoxApplying) {
        self.appearance = appearance
        self.caption = caption
        self.box = box
    }

    // Layout constants. AppKit's origin is bottom-left, so a running `cursor` decrements from the top.
    // Right-aligned controls (readouts, the toggle) hug `contentRight`, kept clear of the tab box's
    // inner border so nothing is clipped at the window edge.
    private enum L {
        static let width: CGFloat = 560
        static let left: CGFloat = 24
        static let right: CGFloat = 36
        static var contentRight: CGFloat { width - right }   // 524
        static let readoutWidth: CGFloat = 56
        static let columnGap: CGFloat = 12
        static let topMargin: CGFloat = 36   // space between the tab bar and the first header
        static let groupGap: CGFloat = 24    // space between the two surface groups
    }

    /// The views for one surface. The `config` rows (size/opacity) are hidden and collapsed when off.
    @MainActor
    private final class SurfaceViews {
        let header = NSTextField(labelWithString: "")
        let toggle = NSSwitch()
        let stateLabel = NSTextField(labelWithString: "")
        let description = NSTextField(labelWithString: "")
        let sizeLabel = NSTextField(labelWithString: "Text Size")
        let sizeSlider: NSSlider
        let sizeReadout = NSTextField(labelWithString: "")
        let opacityLabel: NSTextField
        let opacitySlider: NSSlider
        let opacityReadout = NSTextField(labelWithString: "")

        init(sizeSlider: NSSlider, opacityLabel: NSTextField, opacitySlider: NSSlider) {
            self.sizeSlider = sizeSlider
            self.opacityLabel = opacityLabel
            self.opacitySlider = opacitySlider
        }

        /// The configuration controls hidden/collapsed when the surface is off.
        var configViews: [NSView] { [sizeLabel, sizeSlider, sizeReadout, opacityLabel, opacitySlider, opacityReadout] }
        var allViews: [NSView] { [header, toggle, stateLabel, description] + configViews }
    }

    func makeView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: L.width, height: 432))
        rootView = view

        captionViews = buildSurface(
            in: view, header: "Overlay Caption", description: "A transient response from Jarvis.",
            enabledOn: appearance.captionEnabled, enableAction: #selector(captionEnabledChanged),
            sizeValue: appearance.captionFontSize, sizeRange: Config.overlayCaptionFontSizeRange,
            sizeAction: #selector(captionSizeChanged), sizeA11y: "Overlay caption text size",
            opacityTitle: "Background Opacity", opacityValue: appearance.captionBackgroundOpacity,
            opacityRange: Config.overlayCaptionOpacityRange, opacityAction: #selector(captionOpacityChanged),
            opacityA11y: "Overlay caption background opacity")

        boxViews = buildSurface(
            in: view, header: "Overlay Box", description: "A persistent history of messages from Jarvis.",
            enabledOn: appearance.boxEnabled, enableAction: #selector(boxEnabledChanged),
            sizeValue: appearance.boxFontSize, sizeRange: Config.overlayBoxFontSizeRange,
            sizeAction: #selector(boxSizeChanged), sizeA11y: "Overlay box text size",
            opacityTitle: "Opacity", opacityValue: appearance.boxOpacity,
            opacityRange: Config.overlayBoxOpacityRange, opacityAction: #selector(boxOpacityChanged),
            opacityA11y: "Overlay box opacity")

        updateReadouts()
        relayout()
        return view
    }

    /// Create and style one surface's controls and add them to `view`. Positioning is done later in
    /// `relayout()` so the same code handles the initial layout and every toggle-driven collapse.
    private func buildSurface(
        in view: NSView, header: String, description: String,
        enabledOn: Bool, enableAction: Selector,
        sizeValue: Double, sizeRange: ClosedRange<Double>, sizeAction: Selector, sizeA11y: String,
        opacityTitle: String, opacityValue: Double, opacityRange: ClosedRange<Double>,
        opacityAction: Selector, opacityA11y: String
    ) -> SurfaceViews {
        let sizeSlider = NSSlider(value: sizeValue, minValue: sizeRange.lowerBound,
                                  maxValue: sizeRange.upperBound, target: self, action: sizeAction)
        sizeSlider.setAccessibilityLabel(sizeA11y)
        let opacitySlider = NSSlider(value: opacityValue, minValue: opacityRange.lowerBound,
                                     maxValue: opacityRange.upperBound, target: self, action: opacityAction)
        opacitySlider.setAccessibilityLabel(opacityA11y)
        let s = SurfaceViews(sizeSlider: sizeSlider,
                             opacityLabel: NSTextField(labelWithString: opacityTitle),
                             opacitySlider: opacitySlider)

        s.header.stringValue = header
        s.header.font = .boldSystemFont(ofSize: 13)
        s.header.textColor = .secondaryLabelColor

        s.toggle.controlSize = .small   // match the panel's text scale (the regular switch dwarfed it)
        s.toggle.state = enabledOn ? .on : .off
        s.toggle.target = self
        s.toggle.action = enableAction
        s.toggle.setAccessibilityLabel("Show \(header.lowercased())")
        s.toggle.sizeToFit()

        s.stateLabel.stringValue = enabledOn ? "On" : "Off"
        s.stateLabel.font = .systemFont(ofSize: 13)
        s.stateLabel.alignment = .right
        s.stateLabel.textColor = .secondaryLabelColor

        s.description.stringValue = description
        s.description.font = .systemFont(ofSize: 11)
        s.description.textColor = .tertiaryLabelColor

        s.sizeReadout.alignment = .right
        s.opacityReadout.alignment = .right

        for v in s.allViews { view.addSubview(v) }
        return s
    }

    /// Reposition both groups top-down, collapsing a surface's config + state when it is off.
    private func relayout() {
        guard let root = rootView, let cap = captionViews, let bx = boxViews else { return }
        var cursor = root.frame.height - L.topMargin
        layoutSurface(cap, enabled: appearance.captionEnabled, cursor: &cursor)
        cursor -= L.groupGap
        layoutSurface(bx, enabled: appearance.boxEnabled, cursor: &cursor)
    }

    private func layoutSurface(_ s: SurfaceViews, enabled: Bool, cursor: inout CGFloat) {
        // Header row: bold header at the left, On/Off label + toggle at the right edge.
        cursor -= 20
        s.header.frame = NSRect(x: L.left, y: cursor, width: 300, height: 20)
        let sz = s.toggle.frame.size
        s.toggle.frame = NSRect(x: L.contentRight - sz.width, y: cursor + (20 - sz.height) / 2,
                                width: sz.width, height: sz.height)
        let stateLabelWidth: CGFloat = 30
        s.stateLabel.frame = NSRect(x: s.toggle.frame.minX - 6 - stateLabelWidth, y: cursor,
                                    width: stateLabelWidth, height: 20)

        // Description line.
        cursor -= 4
        cursor -= 16
        s.description.frame = NSRect(x: L.left, y: cursor, width: L.width - 2 * L.left, height: 16)

        // Configuration — shown only when the surface is on; hidden and collapsed when off.
        for v in s.configViews { v.isHidden = !enabled }
        guard enabled else { return }

        cursor -= 12
        layoutSliderRow(label: s.sizeLabel, slider: s.sizeSlider, readout: s.sizeReadout, cursor: &cursor)
        cursor -= 12
        layoutSliderRow(label: s.opacityLabel, slider: s.opacitySlider, readout: s.opacityReadout, cursor: &cursor)
    }

    /// A labelled slider with a right-aligned readout at the shared right margin.
    private func layoutSliderRow(label: NSTextField, slider: NSSlider, readout: NSTextField, cursor: inout CGFloat) {
        cursor -= 20
        label.frame = NSRect(x: L.left, y: cursor, width: 200, height: 20)

        cursor -= 6
        cursor -= 24
        let readoutX = L.contentRight - L.readoutWidth
        let sliderWidth = readoutX - L.columnGap - L.left
        slider.frame = NSRect(x: L.left, y: cursor, width: sliderWidth, height: 24)
        readout.frame = NSRect(x: readoutX, y: cursor + 2, width: L.readoutWidth, height: 20)
    }

    // Preview only while this tab is visible AND the surface is on — an off surface shows no sample.
    func didBecomeActive() {
        caption.showAppearancePreview(appearance.captionEnabled)
        box.showAppearancePreview(appearance.boxEnabled)
    }
    func didResignActive() {
        caption.showAppearancePreview(false)
        box.showAppearancePreview(false)
    }

    // MARK: - Enable toggles

    @objc private func captionEnabledChanged(_ sender: NSSwitch) {
        let on = sender.state == .on
        appearance.captionEnabled = on
        caption.setEnabled(on)
        caption.showAppearancePreview(on)   // the tab is active here; preview only while on
        captionViews?.stateLabel.stringValue = on ? "On" : "Off"
        relayout()
    }

    @objc private func boxEnabledChanged(_ sender: NSSwitch) {
        let on = sender.state == .on
        appearance.boxEnabled = on
        box.setEnabled(on)
        box.showAppearancePreview(on)
        boxViews?.stateLabel.stringValue = on ? "On" : "Off"
        relayout()
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
        if let cap = captionViews {
            let pt = Int(appearance.captionFontSize.rounded())
            let pct = Int((appearance.captionBackgroundOpacity * 100).rounded())
            cap.sizeReadout.stringValue = "\(pt) pt"
            cap.opacityReadout.stringValue = "\(pct)%"
            cap.sizeSlider.setAccessibilityValueDescription("\(pt) points")
            cap.opacitySlider.setAccessibilityValueDescription("\(pct) percent")
        }
        if let bx = boxViews {
            let pt = Int(appearance.boxFontSize.rounded())
            let pct = Int((appearance.boxOpacity * 100).rounded())
            bx.sizeReadout.stringValue = "\(pt) pt"
            bx.opacityReadout.stringValue = "\(pct)%"
            bx.sizeSlider.setAccessibilityValueDescription("\(pt) points")
            bx.opacitySlider.setAccessibilityValueDescription("\(pct) percent")
        }
    }
}
