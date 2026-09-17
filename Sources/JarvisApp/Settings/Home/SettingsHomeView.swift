import AppKit
import JarvisCore

/// Sets no `nextKeyView`: the window recalculates its key view loop.
@MainActor
final class SettingsHomeView: NSView {
    static let wideMinimum = NSSize(width: 780, height: 560)
    private static let stageSize = NSSize(width: 740, height: 282)
    private static let slotSize = NSSize(width: 232, height: 76)
    /// Stage coordinates from the prototype.
    private static let slotOrigins: [RobotPart: NSPoint] = [
        .brain: NSPoint(x: 0, y: 10), .ear: NSPoint(x: 0, y: 152),
        .eye: NSPoint(x: 508, y: 10), .mouth: NSPoint(x: 508, y: 152),
    ]
    private static let connectors: [RobotPart: [NSPoint]] = [
        .brain: [NSPoint(x: 232, y: 46), NSPoint(x: 260, y: 46), NSPoint(x: 312, y: 58)],
        .ear: [NSPoint(x: 232, y: 188), NSPoint(x: 252, y: 188), NSPoint(x: 266, y: 152)],
        .eye: [NSPoint(x: 508, y: 46), NSPoint(x: 480, y: 46), NSPoint(x: 412, y: 116)],
        .mouth: [NSPoint(x: 508, y: 188), NSPoint(x: 480, y: 188), NSPoint(x: 400, y: 208)],
    ]
    private static let dockItems: [(SettingsDestination, String, String)] = [
        (.connections, "Connections", "link"),
        (.tools, "Tools", "wrench.and.screwdriver"),
        (.skills, "Skills", "sparkles"),
        (.shortcuts, "Shortcuts", "command"),
        (.activity, "Activity", "waveform.path.ecg"),
    ]

    let robot = RobotHeadView(style: .hero)
    let meterView = ReadinessMeterView()
    private(set) var slots: [RobotPart: RobotSlotView] = [:]
    private var dockButtons: [HomeDockButton] = []
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "This is me. Pick a part to tune it.")
    private var stageOrigin = NSPoint.zero

    var onOpen: ((SettingsDestination, NSPoint) -> Void)?
    var viewportSize = NSSize.zero {
        didSet { needsLayout = true }
    }
    var highlightedPart: RobotPart? {
        didSet {
            guard oldValue != highlightedPart else { return }
            robot.highlightedPart = highlightedPart
            for (part, slot) in slots { slot.isHighlighted = part == highlightedPart }
            needsDisplay = true
        }
    }
    var isWideLayout: Bool {
        viewportSize.width >= Self.wideMinimum.width && viewportSize.height >= Self.wideMinimum.height
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.attributedStringValue = NSAttributedString(string: "JARVIS", attributes: [
            .kern: 6, .font: NSFont.systemFont(ofSize: 22, weight: .heavy),
            .foregroundColor: SettingsTheme.text,
        ])
        subtitleLabel.font = .systemFont(ofSize: 12.5)
        subtitleLabel.textColor = SettingsTheme.mutedText
        [titleLabel, subtitleLabel, meterView, robot].forEach(addSubview)

        robot.onHover = { [weak self] part in self?.highlightedPart = part }
        robot.onClick = { [weak self] part, point in self?.onOpen?(SettingsDestination(part), point) }
        for part in RobotPart.allCases {
            let slot = RobotSlotView(part: part)
            slot.onHighlight = { [weak self] on in
                guard let self else { return }
                if on { highlightedPart = part } else if highlightedPart == part { highlightedPart = nil }
            }
            slot.onClick = { [weak self] point in self?.onOpen?(SettingsDestination(part), point) }
            slots[part] = slot
            addSubview(slot)
        }
        for (destination, title, symbol) in Self.dockItems {
            let button = HomeDockButton(destination: destination, title: title, symbolName: symbol)
            button.onOpen = { [weak self] destination, point in self?.onOpen?(destination, point) }
            dockButtons.append(button)
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ state: RobotHubState) {
        for (part, slot) in slots {
            if let slotState = state.slots[part] { slot.render(slotState) }
        }
        meterView.render(state.meter)
        robot.isLive = state.isLive
    }

    override func layout() {
        super.layout()
        if isWideLayout { layoutWide() } else { layoutCompact(width: bounds.width) }
    }

    func requiredHeight(forWidth width: CGFloat) -> CGFloat {
        compactFrames(width: width).bottom
    }

    private func layoutWide() {
        let w = bounds.width
        let h = bounds.height
        titleLabel.frame = NSRect(x: 32, y: 22, width: 400, height: 28)
        subtitleLabel.frame = NSRect(x: 32, y: 52, width: 400, height: 18)
        meterView.frame = NSRect(x: w - 32 - 190, y: 26, width: 190, height: 34)

        let dockWidth = CGFloat(dockButtons.count) * 138 + CGFloat(dockButtons.count - 1) * 12
        let dockY = h - 36 - 84
        for (index, button) in dockButtons.enumerated() {
            button.frame = NSRect(x: (w - dockWidth) / 2 + CGFloat(index) * 150, y: dockY, width: 138, height: 84)
        }

        let top: CGFloat = 80
        let free = max(0, dockY - 12 - top - Self.stageSize.height)
        stageOrigin = NSPoint(x: floor((w - Self.stageSize.width) / 2), y: floor(top + free / 2))
        robot.frame = NSRect(x: stageOrigin.x + 256, y: stageOrigin.y,
                             width: RobotHeadView.designCrop.width, height: RobotHeadView.designCrop.height)
        for (part, slot) in slots {
            let origin = Self.slotOrigins[part] ?? .zero
            slot.frame = NSRect(origin: NSPoint(x: stageOrigin.x + origin.x, y: stageOrigin.y + origin.y),
                                size: Self.slotSize)
        }
        needsDisplay = true
    }

    private func layoutCompact(width: CGFloat) {
        let frames = compactFrames(width: width)
        titleLabel.frame = NSRect(x: 24, y: 22, width: 300, height: 28)
        subtitleLabel.frame = NSRect(x: 24, y: 52, width: max(0, width - 48 - 200), height: 18)
        meterView.frame = NSRect(x: width - 24 - 190, y: 26, width: 190, height: 34)
        robot.frame = frames.robot
        for (part, slot) in slots { slot.frame = frames.slots[part] ?? .zero }
        for (button, frame) in zip(dockButtons, frames.dock) { button.frame = frame }
        needsDisplay = true
    }

    private func compactFrames(
        width: CGFloat
    ) -> (robot: NSRect, slots: [RobotPart: NSRect], dock: [NSRect], bottom: CGFloat) {
        let inset: CGFloat = 24
        let gap: CGFloat = 12
        let robot = NSRect(x: floor((width - 140) / 2), y: 84, width: 140, height: 169)
        let columnWidth = floor((width - inset * 2 - gap) / 2)
        let gridTop = robot.maxY + 16
        let grid: [(RobotPart, Int, Int)] = [(.brain, 0, 0), (.eye, 1, 0), (.ear, 0, 1), (.mouth, 1, 1)]
        var slots: [RobotPart: NSRect] = [:]
        for (part, column, row) in grid {
            slots[part] = NSRect(x: inset + CGFloat(column) * (columnWidth + gap),
                                 y: gridTop + CGFloat(row) * (76 + gap),
                                 width: columnWidth, height: 76)
        }
        let dockTop = gridTop + 2 * 76 + gap + 20
        let perRow = max(1, min(dockButtons.count, Int((width - inset * 2 + gap) / (96 + gap))))
        let buttonWidth = floor((width - inset * 2 - gap * CGFloat(perRow - 1)) / CGFloat(perRow))
        var dock: [NSRect] = []
        for index in dockButtons.indices {
            dock.append(NSRect(x: inset + CGFloat(index % perRow) * (buttonWidth + gap),
                               y: dockTop + CGFloat(index / perRow) * (72 + gap),
                               width: buttonWidth, height: 72))
        }
        let bottom = (dock.last?.maxY ?? dockTop) + inset
        return (robot, slots, dock, bottom)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isWideLayout else { return }
        for (part, points) in Self.connectors {
            let path = NSBezierPath()
            path.move(to: offset(points[0]))
            points.dropFirst().forEach { path.line(to: offset($0)) }
            path.lineWidth = 1.3
            (part == highlightedPart ? SettingsTheme.teal : SettingsTheme.purple.withAlphaComponent(0.6)).setStroke()
            path.stroke()
        }
    }

    private func offset(_ point: NSPoint) -> NSPoint {
        NSPoint(x: stageOrigin.x + point.x, y: stageOrigin.y + point.y)
    }
}
