import AppKit
import JarvisCore

@MainActor
final class OverlaySection: NSObject, SettingsSection {
    let destination = SettingsDestination.mouth

    private let onBoxEnabledChanged: (Bool) -> Void
    private let appearance: OverlayAppearance
    private let caption: OverlayCaptionApplying
    private let box: OverlayBoxApplying

    private var scrollView: SettingsScrollView?
    private var documentView: NSView?
    private var captionView: OverlaySurfaceSettingsView?
    private var boxView: OverlaySurfaceSettingsView?

    init(appearance: OverlayAppearance, caption: OverlayCaptionApplying, box: OverlayBoxApplying,
         onBoxEnabledChanged: @escaping (Bool) -> Void = { _ in }) {
        self.onBoxEnabledChanged = onBoxEnabledChanged
        self.appearance = appearance
        self.caption = caption
        self.box = box
    }

    func makePage() -> SettingsPageView {
        let scrollView = SettingsScrollView(
            frame: NSRect(x: 0, y: 0, width: 712, height: 432))
        scrollView.autoresizingMask = [.width, .height]

        let document = NSView(frame: scrollView.bounds)
        document.autoresizingMask = [.width]
        scrollView.documentView = document
        self.scrollView = scrollView
        documentView = document

        captionView = makeSurface(
            title: "Overlay Caption",
            description: "A short tip that fades away.",
            symbolName: "text.bubble",
            enabled: appearance.captionEnabled,
            enableAction: #selector(captionEnabledChanged),
            sizeValue: appearance.captionFontSize,
            sizeRange: Defaults.Overlay.Caption.fontSizeRange,
            sizeAction: #selector(captionSizeChanged),
            sizeAccessibilityLabel: "Overlay caption text size",
            opacityTitle: "Opacity",
            opacityValue: appearance.captionBackgroundOpacity,
            opacityRange: Defaults.Overlay.Caption.opacityRange,
            opacityAction: #selector(captionOpacityChanged),
            opacityAccessibilityLabel: "Overlay caption background opacity")

        boxView = makeSurface(
            title: "Overlay Box",
            description: "Every hint of this session, with details.",
            symbolName: "rectangle.inset.filled",
            enabled: appearance.boxEnabled,
            enableAction: #selector(boxEnabledChanged),
            sizeValue: appearance.boxFontSize,
            sizeRange: Defaults.Overlay.Box.fontSizeRange,
            sizeAction: #selector(boxSizeChanged),
            sizeAccessibilityLabel: "Overlay box text size",
            opacityTitle: "Opacity",
            opacityValue: appearance.boxOpacity,
            opacityRange: Defaults.Overlay.Box.opacityRange,
            opacityAction: #selector(boxOpacityChanged),
            opacityAccessibilityLabel: "Overlay box opacity",
            subordinate: .init(
                title: "Code, diagrams, and explanations",
                sizeTitle: "Detail text size",
                sizeValue: appearance.detailFontSize,
                sizeRange: Defaults.Overlay.Detail.fontSizeRange,
                sizeAction: #selector(detailSizeChanged),
                sizeAccessibilityLabel: "Detail text size",
                opacityTitle: "Detail background opacity",
                opacityValue: appearance.detailBackgroundOpacity,
                opacityRange: Defaults.Overlay.Detail.opacityRange,
                opacityAction: #selector(detailOpacityChanged),
                opacityAccessibilityLabel: "Detail background opacity"))

        if let captionView { document.addSubview(captionView) }
        if let boxView { document.addSubview(boxView) }
        scrollView.onViewportChanged = { [weak self] in self?.relayout() }
        updateReadouts()
        relayout()

        return SettingsPageView(
            title: "Mouth",
            summary: "How my hints show up on your screen.",
            // True in both states: stopped, the sliders act on a sample; live, on the real box.
            chip: .live("Live preview"),
            part: .mouth,
            bodyView: scrollView)
    }

    private func makeSurface(
        title: String,
        description: String,
        symbolName: String,
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
        opacityAccessibilityLabel: String,
        subordinate: OverlaySurfaceSettingsView.SubordinateSliders? = nil
    ) -> OverlaySurfaceSettingsView {
        OverlaySurfaceSettingsView(
            title: title,
            description: description,
            symbolName: symbolName,
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
            opacityAccessibilityLabel: opacityAccessibilityLabel,
            subordinate: subordinate)
    }

    private func relayout() {
        guard let scrollView, let documentView, let captionView, let boxView else { return }

        let viewport = scrollView.contentView.bounds.size
        let width = max(320, viewport.width)
        let boxHeight = boxView.preferredHeight
        let contentHeight =
            captionView.preferredHeight + SettingsStyle.sectionSpacing + boxHeight
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
            y: top - boxHeight,
            width: width,
            height: boxHeight)
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
        relayout()
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
        onBoxEnabledChanged(enabled)
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

    @objc private func detailSizeChanged(_ sender: NSSlider) {
        appearance.detailFontSize = sender.doubleValue.rounded()
        sender.doubleValue = appearance.detailFontSize
        box.setDetailFontSize(appearance.detailFontSize)
        updateReadouts()
    }

    @objc private func detailOpacityChanged(_ sender: NSSlider) {
        appearance.detailBackgroundOpacity = (sender.doubleValue * 100).rounded() / 100
        sender.doubleValue = appearance.detailBackgroundOpacity
        box.setDetailBackgroundOpacity(appearance.detailBackgroundOpacity)
        updateReadouts()
    }

    private func updateReadouts() {
        let detailPoints = Int(appearance.detailFontSize.rounded())
        let detailPercent = Int((appearance.detailBackgroundOpacity * 100).rounded())
        boxView?.updateSubordinateReadouts(size: "\(detailPoints) pt", opacity: "\(detailPercent)%")
        boxView?.subordinateSizeSlider?.setAccessibilityValueDescription("\(detailPoints) points")
        boxView?.subordinateOpacitySlider?
            .setAccessibilityValueDescription("\(detailPercent) percent")
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
