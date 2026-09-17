import AppKit
import QuartzCore

/// Moves between two Settings pages the way the design asks: a page grows out of the point that
/// opened it and shrinks back into the same point, on a critically damped spring. A move that
/// starts mid-animation begins from what is on screen, so reversing is seamless. Under Reduce
/// Motion it only cross-fades. It knows nothing about which pages these are.
@MainActor
enum SettingsPageTransition {
    enum Direction { case forward, back }

    private static let pageScale: CGFloat = 0.86
    private static let hubScale: CGFloat = 1.04

    /// `incoming` and `outgoing` are layer-backed siblings filling the same container; `origin` is in
    /// their shared, unflipped coordinates.
    static func run(
        _ direction: Direction,
        incoming: NSView,
        outgoing: NSView,
        origin: NSPoint,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let inLayer = incoming.layer, let outLayer = outgoing.layer else {
            completion()
            return
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let center = NSPoint(x: incoming.bounds.midX, y: incoming.bounds.midY)
        // Forward: the incoming page grows from the origin while the outgoing view swells and fades.
        // Back: the incoming view settles from slightly large while the page shrinks into the origin.
        let inStart = direction == .forward
            ? scaled(pageScale, about: origin, in: inLayer)
            : scaled(hubScale, about: center, in: inLayer)
        let outEnd = direction == .forward
            ? scaled(hubScale, about: center, in: outLayer)
            : scaled(pageScale, about: origin, in: outLayer)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { completion() }
        }
        animate(inLayer, start: (0, reduce ? CATransform3DIdentity : inStart),
                to: (1, CATransform3DIdentity), reduce: reduce)
        animate(outLayer, start: (1, CATransform3DIdentity),
                to: (0, reduce ? CATransform3DIdentity : outEnd), reduce: reduce)
        CATransaction.commit()
    }

    /// Settles a view with no animation, for a page shown without a move.
    static func reset(_ view: NSView) {
        view.layer?.removeAllAnimations()
        view.layer?.opacity = 1
        view.layer?.transform = CATransform3DIdentity
    }

    private static func animate(
        _ layer: CALayer,
        start: (opacity: Float, transform: CATransform3D),
        to end: (opacity: Float, transform: CATransform3D),
        reduce: Bool
    ) {
        // An interrupted move starts from what is on screen; a fresh one from the given start.
        let isMoving = !(layer.animationKeys() ?? []).isEmpty
        let presentation = layer.presentation()
        let fromOpacity = isMoving ? (presentation?.opacity ?? layer.opacity) : start.opacity
        let fromTransform = isMoving ? (presentation?.transform ?? layer.transform) : start.transform
        layer.removeAllAnimations()
        layer.opacity = end.opacity
        layer.transform = end.transform
        layer.add(animation("opacity", from: fromOpacity, to: end.opacity, reduce: reduce),
                  forKey: "settingsPage.opacity")
        if !reduce {
            layer.add(animation("transform",
                                from: NSValue(caTransform3D: fromTransform),
                                to: NSValue(caTransform3D: end.transform),
                                reduce: false),
                      forKey: "settingsPage.transform")
        }
    }

    private static func animation(_ keyPath: String, from: Any, to: Any, reduce: Bool) -> CAAnimation {
        if reduce {
            let fade = CABasicAnimation(keyPath: keyPath)
            fade.fromValue = from
            fade.toValue = to
            fade.duration = 0.2
            fade.timingFunction = CAMediaTimingFunction(name: .linear)
            return fade
        }
        // Critically damped, 0.38 s response: stiffness = (2π / 0.38)², damping = 4π / 0.38.
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = 273.4
        spring.damping = 33.07
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        return spring
    }

    /// A scale about `point` (in the view's coordinates) for a layer, whatever its anchor point.
    private static func scaled(_ scale: CGFloat, about point: NSPoint, in layer: CALayer) -> CATransform3D {
        let anchor = CGPoint(x: layer.anchorPoint.x * layer.bounds.width,
                             y: layer.anchorPoint.y * layer.bounds.height)
        let x = point.x - anchor.x
        let y = point.y - anchor.y
        var transform = CATransform3DMakeTranslation(x, y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -x, -y, 0)
    }
}
