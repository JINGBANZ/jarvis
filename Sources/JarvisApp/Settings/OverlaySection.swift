import AppKit
import JarvisCore

/// Settings panel for the two overlay surfaces. Both surfaces use the shared Settings page/card/row
/// language while retaining their live enable, appearance, and preview behavior.
@MainActor
final class OverlaySection: NSObject, SettingsSection {
    let title = "Overlay"
    let fillsTab = true

    private let onBoxEnabledChanged: (Bool) -> Void
    private let codePreferences: CodePreferences
    private let onCodeChanged: () -> Void
    private var codeView: OverlaySurfaceSettingsView?
    private let appearance: OverlayAppearance
    private let caption: OverlayCaptionApplying
    private let box: OverlayBoxApplying

    private var scrollView: SettingsScrollView?
    private var documentView: NSView?
    private var captionView: OverlaySurfaceSettingsView?
    private var boxView: OverlaySurfaceSettingsView?

    init(appearance: OverlayAppearance, caption: OverlayCaptionApplying, box: OverlayBoxApplying,
         codePreferences: CodePreferences, onCodeChanged: @escaping () -> Void,
         onBoxEnabledChanged: @escaping (Bool) -> Void = { _ in }) {
        self.codePreferences = codePreferences
        self.onCodeChanged = onCodeChanged
        self.onBoxEnabledChanged = onBoxEnabledChanged
        self.appearance = appearance
        self.caption = caption
        self.box = box
    }

    func makeView() -> NSView {
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
            description: "A brief response that fades after each tip.",
            symbolName: "text.bubble",
            tint: .controlAccentColor,
            enabled: appearance.captionEnabled,
            enableAction: #selector(captionEnabledChanged),
            sizeValue: appearance.captionFontSize,
            sizeRange: Defaults.Overlay.Caption.fontSizeRange,
            sizeAction: #selector(captionSizeChanged),
            sizeAccessibilityLabel: "Overlay caption text size",
            opacityTitle: "Background opacity",
            opacityValue: appearance.captionBackgroundOpacity,
            opacityRange: Defaults.Overlay.Caption.opacityRange,
            opacityAction: #selector(captionOpacityChanged),
            opacityAccessibilityLabel: "Overlay caption background opacity")

        let diagramToggle = NSSwitch()
        diagramToggle.state = appearance.boxDiagramsEnabled ? .on : .off
        diagramToggle.target = self
        diagramToggle.action = #selector(diagramsEnabledChanged)
        diagramToggle.setAccessibilityLabel("Show diagrams")
        diagramToggle.sizeToFit()

        boxView = makeSurface(
            title: "Overlay Box",
            description: "A persistent history of recent Jarvis messages.",
            symbolName: "rectangle.inset.filled",
            tint: .systemOrange,
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
            diagramToggle: diagramToggle)

        codeView = makeSurface(
            title: "Show code with hints",
            description: "Automatic coding snippets · takes effect next Start",
            symbolName: "chevron.left.forwardslash.chevron.right",
            tint: .systemOrange,
            enabled: codePreferences.isEnabled,
            enableAction: #selector(codeEnabledChanged),
            sizeValue: appearance.codeFontSize,
            sizeRange: Defaults.Overlay.Code.fontSizeRange,
            sizeAction: #selector(codeSizeChanged),
            sizeAccessibilityLabel: "Code text size",
            opacityTitle: "Background opacity",
            opacityValue: appearance.codeBackgroundOpacity,
            opacityRange: Defaults.Overlay.Code.opacityRange,
            opacityAction: #selector(codeOpacityChanged),
            opacityAccessibilityLabel: "Code background opacity")
        codeView?.toggle.setAccessibilityLabel("Show code with hints")
        boxView?.supplementaryView = codeView
        boxView?.updateEnabledState(appearance.boxEnabled)

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
        opacityAccessibilityLabel: String,
        diagramToggle: NSSwitch? = nil
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
            opacityAccessibilityLabel: opacityAccessibilityLabel,
            diagramToggle: diagramToggle)
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
        codeView?.updateEnabledState(codePreferences.isEnabled)
        box.setCodePreviewEnabled(codePreferences.isEnabled)
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

    @objc private func diagramsEnabledChanged(_ sender: NSSwitch) {
        appearance.boxDiagramsEnabled = sender.state == .on
        box.setDiagramsEnabled(appearance.boxDiagramsEnabled)
    }

    @objc private func boxEnabledChanged(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        appearance.boxEnabled = enabled
        onBoxEnabledChanged(enabled)
        box.setEnabled(enabled)
        box.showAppearancePreview(enabled)
        codeView?.updateEnabledState(codePreferences.isEnabled)
        box.setCodePreviewEnabled(codePreferences.isEnabled)
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

    @objc private func codeEnabledChanged(_ sender: NSSwitch) {
        codePreferences.isEnabled = sender.state == .on
        onCodeChanged()
        codeView?.updateEnabledState(codePreferences.isEnabled)
        box.setCodePreviewEnabled(codePreferences.isEnabled)
        relayout()
    }

    @objc private func codeSizeChanged(_ sender: NSSlider) {
        appearance.codeFontSize = sender.doubleValue.rounded()
        sender.doubleValue = appearance.codeFontSize
        box.setCodeFontSize(appearance.codeFontSize)
        updateReadouts()
    }

    @objc private func codeOpacityChanged(_ sender: NSSlider) {
        appearance.codeBackgroundOpacity = (sender.doubleValue * 100).rounded() / 100
        sender.doubleValue = appearance.codeBackgroundOpacity
        box.setCodeBackgroundOpacity(appearance.codeBackgroundOpacity)
        updateReadouts()
    }

    private func updateReadouts() {
        let codePoints = Int(appearance.codeFontSize.rounded())
        let codePercent = Int((appearance.codeBackgroundOpacity * 100).rounded())
        codeView?.updateReadouts(size: "\(codePoints) pt", opacity: "\(codePercent)%")
        codeView?.sizeSlider.setAccessibilityValueDescription("\(codePoints) points")
        codeView?.opacitySlider.setAccessibilityValueDescription("\(codePercent) percent")
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
