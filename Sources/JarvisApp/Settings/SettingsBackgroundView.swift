import AppKit

/// The backdrop behind every Settings page: a soft radial glow, redrawn per appearance.
@MainActor
final class SettingsBackgroundView: NSView {
    private let gradient = CAGradientLayer()

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradient.type = .radial
        // Layer space is y-up, so 0.58 puts the glow a little above center, as in the prototype.
        gradient.startPoint = CGPoint(x: 0.5, y: 0.58)
        gradient.endPoint = CGPoint(x: 1.15, y: 1.25)
        layer?.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    override func updateLayer() {
        gradient.colors = [SettingsTheme.backgroundCenter.cgColor, SettingsTheme.backgroundEdge.cgColor]
    }
}
