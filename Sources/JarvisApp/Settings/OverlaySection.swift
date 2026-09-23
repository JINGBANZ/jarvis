import AppKit
import JarvisCore

@MainActor
final class OverlaySection: NSObject, SettingsSection {
    let destination = SettingsDestination.mouth

    private let appearance: OverlayAppearance
    private let box: OverlayBoxApplying

    private var scrollView: SettingsScrollView?
    private var documentView: NSView?
    private var boxView: OverlaySurfaceSettingsView?

    init(appearance: OverlayAppearance, box: OverlayBoxApplying) {
        self.appearance = appearance
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

        boxView = OverlaySurfaceSettingsView(
            title: "Overlay Box",
            description: "Every hint of this session, with details.",
            symbolName: "rectangle.inset.filled",
            target: self,
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

    private func relayout() {
        guard let scrollView, let documentView, let boxView else { return }

        let viewport = scrollView.contentView.bounds.size
        let width = max(320, viewport.width)
        let boxHeight = boxView.preferredHeight
        let documentHeight = max(viewport.height, boxHeight)

        documentView.frame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
        boxView.frame = NSRect(
            x: 0,
            y: documentHeight - boxHeight,
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
        box.showAppearancePreview(true)
    }

    func didResignActive() {
        box.showAppearancePreview(false)
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
        let boxPoints = Int(appearance.boxFontSize.rounded())
        let boxPercent = Int((appearance.boxOpacity * 100).rounded())
        boxView?.updateReadouts(size: "\(boxPoints) pt", opacity: "\(boxPercent)%")
        boxView?.sizeSlider.setAccessibilityValueDescription("\(boxPoints) points")
        boxView?.opacitySlider.setAccessibilityValueDescription("\(boxPercent) percent")
    }
}
