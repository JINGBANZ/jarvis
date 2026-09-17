import AppKit
import JarvisCore

/// The hub header's readiness meter: a label over one segment per part, teal when that part is
/// ready and amber when it needs the user.
@MainActor
final class ReadinessMeterView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let segments = (0..<RobotPart.allCases.count).map { _ in CALayer() }
    private var ready: [Bool] = []

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 34))
        wantsLayer = true
        isHidden = true
        label.alignment = .right
        addSubview(label)
        for segment in segments {
            segment.cornerRadius = 2
            segment.shadowOffset = .zero
            segment.shadowRadius = 3
            segment.shadowOpacity = 1
            layer?.addSublayer(segment)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ meter: RobotHubMeter?) {
        isHidden = meter == nil
        guard let meter else { return }
        ready = meter.ready
        let tone = switch meter.tone {
        case .normal: SettingsTheme.mutedText
        case .live: SettingsTheme.teal
        case .attention: SettingsTheme.amber
        }
        label.attributedStringValue = NSAttributedString(string: meter.label, attributes: [
            .kern: 2, .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: tone,
        ])
        setAccessibilityLabel(meter.label.capitalized)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 14)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width: CGFloat = 36
        let gap: CGFloat = 6
        let start = bounds.width - CGFloat(segments.count) * width - CGFloat(segments.count - 1) * gap
        for (index, segment) in segments.enumerated() {
            segment.frame = CGRect(x: start + CGFloat(index) * (width + gap), y: 22, width: width, height: 8)
        }
        CATransaction.commit()
    }

    override func updateLayer() {
        for (index, segment) in segments.enumerated() {
            let isReady = ready.indices.contains(index) ? ready[index] : true
            let color = (isReady ? SettingsTheme.teal : SettingsTheme.amber).cgColor
            segment.backgroundColor = color
            segment.shadowColor = color
        }
    }
}
