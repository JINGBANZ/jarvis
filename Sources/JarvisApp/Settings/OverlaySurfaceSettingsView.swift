import AppKit

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

    struct SubordinateSliders {
        let title: String
        let sizeTitle: String
        let sizeValue: Double
        let sizeRange: ClosedRange<Double>
        let sizeAction: Selector
        let sizeAccessibilityLabel: String
        let opacityTitle: String
        let opacityValue: Double
        let opacityRange: ClosedRange<Double>
        let opacityAction: Selector
        let opacityAccessibilityLabel: String
    }

    let toggle = NSSwitch()
    let sizeSlider: NSSlider
    let opacitySlider: NSSlider
    private(set) var subordinateSizeSlider: NSSlider?
    private(set) var subordinateOpacitySlider: NSSlider?

    private let card = SettingsCardView(frame: .zero)
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let sizeControl: SliderControlView
    private let opacityControl: SliderControlView
    private let sizeRow: SettingsRowView
    private let opacityRow: SettingsRowView
    private var subordinateSizeControl: SliderControlView?
    private var subordinateOpacityControl: SliderControlView?
    private var subordinateRows: [SettingsRowView] = []

    var preferredHeight: CGFloat {
        guard toggle.state == .on else { return Self.headerHeight }
        return Self.headerHeight + SettingsStyle.rowHeight * CGFloat(2 + subordinateRows.count)
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
        opacityAccessibilityLabel: String,
        subordinate: SubordinateSliders? = nil
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
        toggle.setAccessibilityLabel(title.hasPrefix("Show ") ? title : "Show \(title.lowercased())")
        stateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stateLabel.alignment = .right
        stateLabel.textColor = .secondaryLabelColor

        sizeSlider.setAccessibilityLabel(sizeAccessibilityLabel)
        opacitySlider.setAccessibilityLabel(opacityAccessibilityLabel)
        if let subordinate {
            let size = NSSlider(value: subordinate.sizeValue,
                                minValue: subordinate.sizeRange.lowerBound,
                                maxValue: subordinate.sizeRange.upperBound,
                                target: target, action: subordinate.sizeAction)
            size.setAccessibilityLabel(subordinate.sizeAccessibilityLabel)
            let opacity = NSSlider(value: subordinate.opacityValue,
                                   minValue: subordinate.opacityRange.lowerBound,
                                   maxValue: subordinate.opacityRange.upperBound,
                                   target: target, action: subordinate.opacityAction)
            opacity.setAccessibilityLabel(subordinate.opacityAccessibilityLabel)
            let sizeControl = SliderControlView(slider: size)
            let opacityControl = SliderControlView(slider: opacity)
            subordinateSizeSlider = size
            subordinateOpacitySlider = opacity
            subordinateSizeControl = sizeControl
            subordinateOpacityControl = opacityControl
            subordinateRows = [
                SettingsRowView(title: subordinate.sizeTitle, detail: subordinate.title,
                                controlView: sizeControl,
                                controlSize: NSSize(width: 310, height: 32)),
                SettingsRowView(title: subordinate.opacityTitle, controlView: opacityControl,
                                controlSize: NSSize(width: 310, height: 32)),
            ]
        }
        updateEnabledState(enabled)

        guard let content = card.contentView else { return }
        for view in [
            icon, titleLabel, descriptionLabel, stateLabel, toggle, sizeRow, opacityRow,
        ] {
            content.addSubview(view)
        }
        for row in subordinateRows { content.addSubview(row) }
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
        for row in subordinateRows { row.isHidden = !enabled }
        needsLayout = true
    }

    func updateReadouts(size: String, opacity: String) {
        sizeControl.readout.stringValue = size
        opacityControl.readout.stringValue = opacity
    }

    func updateSubordinateReadouts(size: String, opacity: String) {
        subordinateSizeControl?.readout.stringValue = size
        subordinateOpacityControl?.readout.stringValue = opacity
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
            sizeRow.frame = NSRect(
                x: 0,
                y: headerY - SettingsStyle.rowHeight,
                width: content.bounds.width,
                height: SettingsStyle.rowHeight)
            opacityRow.frame = NSRect(
                x: 0,
                y: headerY - SettingsStyle.rowHeight * 2,
                width: content.bounds.width,
                height: SettingsStyle.rowHeight)
            for (index, row) in subordinateRows.enumerated() {
                row.frame = NSRect(
                    x: 0,
                    y: headerY - SettingsStyle.rowHeight * CGFloat(3 + index),
                    width: content.bounds.width,
                    height: SettingsStyle.rowHeight)
            }
        }
    }
}
