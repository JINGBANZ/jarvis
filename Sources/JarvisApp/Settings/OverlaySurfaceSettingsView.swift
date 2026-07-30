import AppKit

/// One Overlay Settings card: surface identity/toggle plus the shared size and opacity rows.
@MainActor
final class OverlaySurfaceSettingsView: NSView {
    private static let headerHeight: CGFloat = 62

    @MainActor
    private final class SliderControlView: NSView {
        let slider: NSSlider
        let readout = NSTextField(labelWithString: "")

        init(slider: NSSlider) {
            self.slider = slider
            super.init(frame: NSRect(x: 0, y: 0, width: 310, height: 32))
            readout.alignment = .right
            readout.textColor = .secondaryLabelColor
            addSubview(slider)
            addSubview(readout)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            let readoutWidth: CGFloat = 52
            let gap: CGFloat = 10
            slider.frame = NSRect(
                x: 0,
                y: 4,
                width: max(80, bounds.width - readoutWidth - gap),
                height: 24)
            readout.frame = NSRect(
                x: bounds.width - readoutWidth,
                y: 6,
                width: readoutWidth,
                height: 20)
        }
    }

    let toggle = NSSwitch()
    let sizeSlider: NSSlider
    let opacitySlider: NSSlider

    private let card = SettingsCardView(frame: .zero)
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let sizeControl: SliderControlView
    private let opacityControl: SliderControlView
    private let sizeRow: SettingsRowView
    private let opacityRow: SettingsRowView

    var preferredHeight: CGFloat {
        Self.headerHeight + (toggle.state == .on ? SettingsStyle.rowHeight * 2 : 0)
    }

    init(
        title: String,
        description: String,
        symbolName: String,
        tint: NSColor,
        enabled: Bool,
        target: AnyObject,
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
    ) {
        sizeSlider = NSSlider(
            value: sizeValue,
            minValue: sizeRange.lowerBound,
            maxValue: sizeRange.upperBound,
            target: target,
            action: sizeAction)
        opacitySlider = NSSlider(
            value: opacityValue,
            minValue: opacityRange.lowerBound,
            maxValue: opacityRange.upperBound,
            target: target,
            action: opacityAction)
        sizeControl = SliderControlView(slider: sizeSlider)
        opacityControl = SliderControlView(slider: opacitySlider)
        sizeRow = SettingsRowView(
            title: "Text size",
            controlView: sizeControl,
            controlSize: NSSize(width: 310, height: 32))
        opacityRow = SettingsRowView(
            title: opacityTitle,
            controlView: opacityControl,
            controlSize: NSSize(width: 310, height: 32))

        super.init(frame: NSRect(x: 0, y: 0, width: 712, height: 174))
        autoresizingMask = [.width]

        icon.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        icon.contentTintColor = tint

        titleLabel.stringValue = title
        titleLabel.font = .boldSystemFont(ofSize: 13)
        descriptionLabel.stringValue = description
        descriptionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.lineBreakMode = .byTruncatingTail

        toggle.state = enabled ? .on : .off
        toggle.target = target
        toggle.action = enableAction
        toggle.setAccessibilityLabel("Show \(title.lowercased())")
        stateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stateLabel.alignment = .right
        stateLabel.textColor = .secondaryLabelColor

        sizeSlider.setAccessibilityLabel(sizeAccessibilityLabel)
        opacitySlider.setAccessibilityLabel(opacityAccessibilityLabel)
        updateEnabledState(enabled)

        guard let content = card.contentView else { return }
        for view in [
            icon, titleLabel, descriptionLabel, stateLabel, toggle, sizeRow, opacityRow,
        ] {
            content.addSubview(view)
        }
        addSubview(card)
        card.onLayout = { [weak self] in self?.layoutContent() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateEnabledState(_ enabled: Bool) {
        toggle.state = enabled ? .on : .off
        stateLabel.stringValue = enabled ? "On" : "Off"
        sizeRow.isHidden = !enabled
        opacityRow.isHidden = !enabled
        needsLayout = true
    }

    func updateReadouts(size: String, opacity: String) {
        sizeControl.readout.stringValue = size
        opacityControl.readout.stringValue = opacity
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        layoutContent()
    }

    private func layoutContent() {
        guard let content = card.contentView else { return }
        let headerY = content.bounds.height - Self.headerHeight

        icon.frame = NSRect(x: 16, y: headerY + 17, width: 28, height: 28)
        titleLabel.frame = NSRect(
            x: 54,
            y: headerY + 32,
            width: max(100, content.bounds.width - 200),
            height: 19)
        descriptionLabel.frame = NSRect(
            x: 54,
            y: headerY + 13,
            width: max(100, content.bounds.width - 200),
            height: 17)
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(
            x: content.bounds.width - 16 - toggle.frame.width,
            y: headerY + (Self.headerHeight - toggle.frame.height) / 2)
        stateLabel.frame = NSRect(
            x: toggle.frame.minX - 38,
            y: headerY + 22,
            width: 30,
            height: 18)

        if toggle.state == .on {
            opacityRow.frame = NSRect(
                x: 0,
                y: 0,
                width: content.bounds.width,
                height: SettingsStyle.rowHeight)
            sizeRow.frame = NSRect(
                x: 0,
                y: SettingsStyle.rowHeight,
                width: content.bounds.width,
                height: SettingsStyle.rowHeight)
        }
    }
}
