import AppKit
import JarvisCore

/// Settings panel for the two overlay surfaces. Both surfaces use the shared Settings page/card/row
/// language while retaining their live enable, appearance, and preview behavior.
@MainActor
final class OverlaySection: NSObject, SettingsSection {
    let title = "Overlay"
    let fillsTab = true

    private let appearance: OverlayAppearance
    private let caption: OverlayCaptionApplying
    private let box: OverlayBoxApplying

    private var scrollView: SettingsScrollView?
    private var documentView: NSView?
    private var captionView: OverlaySurfaceSettingsView?
    private var boxView: OverlaySurfaceSettingsView?

    init(appearance: OverlayAppearance, caption: OverlayCaptionApplying, box: OverlayBoxApplying) {
        self.appearance = appearance
        self.caption = caption
        self.box = box
    }

    func makeView() -> NSView {
        let scrollView = SettingsScrollView(
            frame: NSRect(x: 0, y: 0, width: 712, height: 432))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let document = NSView(frame: scrollView.bounds)
        document.autoresizingMask = [.width]
        scrollView.documentView = document
        self.scrollView = scrollView
        documentView = document

        captionView = makeSurface(
            title: "Overlay Caption",
            description: "A brief response that fades after each tip.",
            symbolName: "text.bubble",
            tint: .controlAccentColor,
            enabled: appearance.captionEnabled,
            enableAction: #selector(captionEnabledChanged),
            sizeValue: appearance.captionFontSize,
            sizeRange: Config.overlayCaptionFontSizeRange,
            sizeAction: #selector(captionSizeChanged),
            sizeAccessibilityLabel: "Overlay caption text size",
            opacityTitle: "Background opacity",
            opacityValue: appearance.captionBackgroundOpacity,
            opacityRange: Config.overlayCaptionOpacityRange,
            opacityAction: #selector(captionOpacityChanged),
            opacityAccessibilityLabel: "Overlay caption background opacity")

        boxView = makeSurface(
            title: "Overlay Box",
            description: "A persistent history of recent Jarvis messages.",
            symbolName: "rectangle.inset.filled",
            tint: .systemOrange,
            enabled: appearance.boxEnabled,
            enableAction: #selector(boxEnabledChanged),
            sizeValue: appearance.boxFontSize,
            sizeRange: Config.overlayBoxFontSizeRange,
            sizeAction: #selector(boxSizeChanged),
            sizeAccessibilityLabel: "Overlay box text size",
            opacityTitle: "Opacity",
            opacityValue: appearance.boxOpacity,
            opacityRange: Config.overlayBoxOpacityRange,
            opacityAction: #selector(boxOpacityChanged),
            opacityAccessibilityLabel: "Overlay box opacity")

        if let captionView { document.addSubview(captionView) }
        if let boxView { document.addSubview(boxView) }
        scrollView.onViewportChanged = { [weak self] in self?.relayout() }
        updateReadouts()
        relayout()

        return SettingsPageView(
            title: "Overlay",
            summary: "Tune the two capture-invisible coaching surfaces.",
            status: "Live preview",
            bodyView: scrollView)
    }

    private func makeSurface(
        title: String,
        description: String,
        symbolName: String,
        tint: NSColor,
        enabled: Bool,
        enableAction: Selector,
        sizeValue: Double,
        sizeRange: ClosedRange<Double>,
        sizeAction: Selector,
        sizeAccessibilityLabel: String,
        opacityTitle: String,
        opacityValue: Double,
        opacityRange: ClosedRange<Double>,
        opacityAction: Selector,
        opacityAccessibilityLabel: String
    ) -> OverlaySurfaceSettingsView {
        OverlaySurfaceSettingsView(
            title: title,
            description: description,
            symbolName: symbolName,
            tint: tint,
            enabled: enabled,
            target: self,
            enableAction: enableAction,
            sizeValue: sizeValue,
            sizeRange: sizeRange,
            sizeAction: sizeAction,
            sizeAccessibilityLabel: sizeAccessibilityLabel,
            opacityTitle: opacityTitle,
            opacityValue: opacityValue,
            opacityRange: opacityRange,
            opacityAction: opacityAction,
            opacityAccessibilityLabel: opacityAccessibilityLabel)
    }

    private func relayout() {
        guard let scrollView, let documentView, let captionView, let boxView else { return }

        let viewport = scrollView.contentView.bounds.size
        let width = max(320, viewport.width)
        let contentHeight =
            captionView.preferredHeight + SettingsStyle.sectionSpacing + boxView.preferredHeight
        let documentHeight = max(viewport.height, contentHeight)

        documentView.frame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
        var top = documentHeight
        captionView.frame = NSRect(
            x: 0,
            y: top - captionView.preferredHeight,
            width: width,
            height: captionView.preferredHeight)
        top = captionView.frame.minY - SettingsStyle.sectionSpacing
        boxView.frame = NSRect(
            x: 0,
            y: top - boxView.preferredHeight,
            width: width,
            height: boxView.preferredHeight)
        revealTop()
    }

    private func revealTop() {
        guard let scrollView, let documentView else { return }
        scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: max(0, documentView.bounds.height - scrollView.contentView.bounds.height)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func didBecomeActive() {
        caption.showAppearancePreview(appearance.captionEnabled)
        box.showAppearancePreview(appearance.boxEnabled)
    }

    func didResignActive() {
        caption.showAppearancePreview(false)
        box.showAppearancePreview(false)
    }

    @objc private func captionEnabledChanged(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        appearance.captionEnabled = enabled
        caption.setEnabled(enabled)
        caption.showAppearancePreview(enabled)
        captionView?.updateEnabledState(enabled)
        relayout()
    }

    @objc private func boxEnabledChanged(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        appearance.boxEnabled = enabled
        box.setEnabled(enabled)
        box.showAppearancePreview(enabled)
        boxView?.updateEnabledState(enabled)
        relayout()
    }

    @objc private func captionSizeChanged(_ sender: NSSlider) {
        appearance.captionFontSize = sender.doubleValue.rounded()
        sender.doubleValue = appearance.captionFontSize
        caption.setFontSize(appearance.captionFontSize)
        updateReadouts()
    }

    @objc private func captionOpacityChanged(_ sender: NSSlider) {
        appearance.captionBackgroundOpacity = (sender.doubleValue * 100).rounded() / 100
        sender.doubleValue = appearance.captionBackgroundOpacity
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
        let captionPoints = Int(appearance.captionFontSize.rounded())
        let captionPercent = Int((appearance.captionBackgroundOpacity * 100).rounded())
        captionView?.updateReadouts(
            size: "\(captionPoints) pt",
            opacity: "\(captionPercent)%")
        captionView?.sizeSlider.setAccessibilityValueDescription("\(captionPoints) points")
        captionView?.opacitySlider.setAccessibilityValueDescription("\(captionPercent) percent")

        let boxPoints = Int(appearance.boxFontSize.rounded())
        let boxPercent = Int((appearance.boxOpacity * 100).rounded())
        boxView?.updateReadouts(size: "\(boxPoints) pt", opacity: "\(boxPercent)%")
        boxView?.sizeSlider.setAccessibilityValueDescription("\(boxPoints) points")
        boxView?.opacitySlider.setAccessibilityValueDescription("\(boxPercent) percent")
    }
}
