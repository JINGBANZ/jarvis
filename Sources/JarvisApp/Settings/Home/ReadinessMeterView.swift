import AppKit
import JarvisCore

@MainActor
final class ReadinessMeterView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let segments = (0..<RobotPart.allCases.count).map { _ in CALayer() }
    private var signals: [RobotSlotState.Tone] = []

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 34))
        wantsLayer = true
        isHidden = true
        label.alignment = .left
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
        signals = meter.signals
        let tone = switch meter.tone {
        case .normal: SettingsTheme.mutedText
        case .live: SettingsTheme.teal
        case .attention: SettingsTheme.amber
        case .blocked: SettingsTheme.red
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
        let gap: CGFloat = 6
        let count = CGFloat(segments.count)
        let width = (bounds.width - (count - 1) * gap) / count
        for (index, segment) in segments.enumerated() {
            segment.frame = CGRect(x: CGFloat(index) * (width + gap), y: 22, width: width, height: 8)
        }
        CATransaction.commit()
    }

    override func updateLayer() {
        for (index, segment) in segments.enumerated() {
            let tone = signals.indices.contains(index) ? signals[index] : .normal
            let color = switch tone {
            case .normal, .live: SettingsTheme.teal.cgColor
            case .attention: SettingsTheme.amber.cgColor
            case .blocked: SettingsTheme.red.cgColor
            }
            segment.backgroundColor = color
            segment.shadowColor = color
        }
    }
}
