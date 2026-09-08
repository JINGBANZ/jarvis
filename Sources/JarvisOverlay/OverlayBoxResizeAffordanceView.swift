import AppKit

/// A transparent sheet over the Overlay Box that draws its resize affordance.
///
/// The panel has always been resizable, but a borderless window has no chrome to advertise it. The
/// obvious answer, a resize cursor, is not available: macOS refuses to let an inactive application
/// change the cursor, and Jarvis is a background app for all of a session, so a cursor would appear
/// only in the one state where Settings happens to be open. Apple's own `screencapture` reaches for
/// private SkyLight calls to get around that, which is not a dependency worth taking for a cursor.
/// So the panel draws the affordance itself, the way Picture-in-Picture does: an outline while the
/// pointer is anywhere inside, and a brighter run on whichever edge or corner it is over.
///
/// The events, unlike the cursor, do arrive while inactive. One `.activeAlways` tracking area is
/// enough, and this view turns the pointer's position into one of eight zones.
///
/// It takes no part in hit testing, so clicks still reach the header buttons underneath and a drag
/// anywhere still moves the window.
final class OverlayBoxResizeAffordanceView: NSView {
    /// Which edge or corner of the box the pointer is over.
    enum Zone: Hashable, CaseIterable {
        case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight
    }

    /// How close to an edge the pointer must be for that edge to claim it.
    private static let edgeReach: CGFloat = 6
    /// How far along an edge a corner still claims the pointer.
    private static let cornerReach: CGFloat = 14
    /// Matches the panel's `layer.cornerRadius`, so the corner runs arc through the box's own curve.
    private static let cornerRadius: CGFloat = 12

    /// Quiet enough to ignore while reading a tip, present enough to answer "is this resizable".
    private static let outlineWidth: CGFloat = 1
    private static let outlineAlpha: CGFloat = 0.18
    private static let runWidth: CGFloat = 2
    private static let runAlpha: CGFloat = 0.78
    private static let outlineFade: CFTimeInterval = 0.14
    private static let runFade: CFTimeInterval = 0.12

    /// Collapsed, the box's height is the header's, so a vertical drag has nothing to do.
    var allowsVerticalResize = true {
        didSet {
            guard allowsVerticalResize != oldValue else { return }
            rebuildPaths()
            // The run under the pointer may have just become undraggable.
            if let highlightedZone, runPaths[highlightedZone] == nil { highlight(nil) }
        }
    }

    private let outlineLayer = CAShapeLayer()
    private let runLayer = CAShapeLayer()
    private var runPaths: [Zone: CGPath] = [:]
    private(set) var highlightedZone: Zone?
    private var edgeTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for (shape, width, alpha) in [(outlineLayer, Self.outlineWidth, Self.outlineAlpha),
                                      (runLayer, Self.runWidth, Self.runAlpha)] {
            shape.fillColor = nil
            shape.strokeColor = NSColor(white: 1, alpha: alpha).cgColor
            shape.lineWidth = width
            shape.lineCap = .round
            shape.opacity = 0
            layer?.addSublayer(shape)
        }
        rebuildPaths()
    }

    required init?(coder: NSCoder) { fatalError("built in code; this project has no nibs") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildPaths()
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let edgeTracking { removeTrackingArea(edgeTracking) }
        // `.inVisibleRect` keeps the area matched to the view as the box is dragged wider or taller,
        // which is exactly when the edges move (the `rect` is then ignored). `.activeAlways` is what
        // gets these events delivered while Jarvis is not the active app, which is nearly always.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self)
        addTrackingArea(area)
        edgeTracking = area
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved(to: location(of: event)) }
    override func mouseEntered(with event: NSEvent) { pointerMoved(to: location(of: event)) }
    override func mouseExited(with event: NSEvent) { pointerMoved(to: nil) }

    private func location(of event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }

    /// The one entry point for every pointer event: nil means the pointer has left the box.
    func pointerMoved(to point: NSPoint?) {
        guard let point, bounds.contains(point) else {
            showOutline(false)
            highlight(nil)
            return
        }
        showOutline(true)
        highlight(Self.zone(at: point, in: bounds, allowsVerticalResize: allowsVerticalResize))
    }

    private func showOutline(_ shown: Bool) {
        guard (outlineLayer.opacity > 0) != shown else { return }
        fade(outlineLayer, to: shown ? 1 : 0, over: Self.outlineFade)
    }

    private func highlight(_ zone: Zone?) {
        guard zone != highlightedZone else { return }
        highlightedZone = zone
        // Swapping the path outright rather than cross-fading two layers: adjacent runs are 120 ms
        // apart, and a moment with both lit would read as a glitch rather than as a transition.
        if let zone, let path = runPaths[zone] {
            runLayer.path = path
            fade(runLayer, to: 1, over: Self.runFade)
        } else {
            fade(runLayer, to: 0, over: Self.runFade)
        }
    }

    private func fade(_ shape: CAShapeLayer, to opacity: Float, over duration: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration)
        shape.opacity = opacity
        CATransaction.commit()
    }

    // MARK: - Geometry

    /// The zone a point falls in, or nil for the box's interior. Pure, so the geometry can be checked
    /// without a window.
    static func zone(at point: NSPoint, in bounds: NSRect, allowsVerticalResize: Bool) -> Zone? {
        let left = point.x - bounds.minX
        let right = bounds.maxX - point.x
        let top = bounds.maxY - point.y
        let bottom = point.y - bounds.minY
        guard min(left, right, top, bottom) >= 0 else { return nil }

        let onLeft = left <= edgeReach, onRight = right <= edgeReach
        let onTop = allowsVerticalResize && top <= edgeReach
        let onBottom = allowsVerticalResize && bottom <= edgeReach
        let nearLeft = left <= cornerReach, nearRight = right <= cornerReach
        let nearTop = allowsVerticalResize && top <= cornerReach
        let nearBottom = allowsVerticalResize && bottom <= cornerReach

        // A corner claims the pointer when it is on one of its edges and near the other, so the
        // diagonal is reachable by sliding along either edge rather than only where the two meet.
        if (onTop && nearLeft) || (onLeft && nearTop) { return .topLeft }
        if (onTop && nearRight) || (onRight && nearTop) { return .topRight }
        if (onBottom && nearLeft) || (onLeft && nearBottom) { return .bottomLeft }
        if (onBottom && nearRight) || (onRight && nearBottom) { return .bottomRight }
        if onTop { return .top }
        if onBottom { return .bottom }
        if onLeft { return .left }
        if onRight { return .right }
        return nil
    }

    /// The panel clips to its rounded corners (`box.layer.masksToBounds`), so a stroke centred on the
    /// box's edge would lose its outer half. Each shape is inset by its own half-width plus one point,
    /// which puts the whole stroke inside the clip and reads as a hairline just within the edge.
    private func rebuildPaths() {
        let outlineInset = Self.outlineWidth / 2 + 1
        let runInset = Self.runWidth / 2 + 1
        let frame = bounds.insetBy(dx: runInset, dy: runInset)
        guard frame.width > 2 * Self.cornerRadius, frame.height > 0 else {
            outlineLayer.path = nil
            runLayer.path = nil
            runPaths = [:]
            return
        }
        outlineLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: outlineInset, dy: outlineInset),
            cornerWidth: Self.cornerRadius - outlineInset,
            cornerHeight: Self.cornerRadius - outlineInset,
            transform: nil)
        runPaths = allowsVerticalResize
            ? Self.fullRuns(in: frame, radius: Self.cornerRadius - runInset)
            : Self.sideCaps(in: frame, radius: Self.cornerRadius - runInset)
        runLayer.path = highlightedZone.flatMap { runPaths[$0] }
    }

    /// Four straight edge runs plus four corner Ls that arc through the box's radius.
    private static func fullRuns(in frame: NSRect, radius r: CGFloat) -> [Zone: CGPath] {
        let (x0, y0, x1, y1) = (frame.minX, frame.minY, frame.maxX, frame.maxY)
        let arm = cornerReach

        func line(_ from: CGPoint, _ to: CGPoint) -> CGPath {
            let path = CGMutablePath()
            path.move(to: from)
            path.addLine(to: to)
            return path
        }
        /// An L: along one edge, around the arc, out along the other.
        func corner(_ start: CGPoint, _ arcStart: CGPoint, _ center: CGPoint,
                    _ from: CGFloat, _ to: CGFloat, _ end: CGPoint) -> CGPath {
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: arcStart)
            path.addArc(center: center, radius: r, startAngle: from, endAngle: to, clockwise: true)
            path.addLine(to: end)
            return path
        }

        return [
            .top: line(CGPoint(x: x0 + r + arm, y: y1), CGPoint(x: x1 - r - arm, y: y1)),
            .bottom: line(CGPoint(x: x0 + r + arm, y: y0), CGPoint(x: x1 - r - arm, y: y0)),
            .left: line(CGPoint(x: x0, y: y0 + r + arm), CGPoint(x: x0, y: y1 - r - arm)),
            .right: line(CGPoint(x: x1, y: y0 + r + arm), CGPoint(x: x1, y: y1 - r - arm)),
            .topLeft: corner(CGPoint(x: x0, y: y1 - r - arm), CGPoint(x: x0, y: y1 - r),
                             CGPoint(x: x0 + r, y: y1 - r), .pi, .pi / 2,
                             CGPoint(x: x0 + r + arm, y: y1)),
            .topRight: corner(CGPoint(x: x1 - r - arm, y: y1), CGPoint(x: x1 - r, y: y1),
                              CGPoint(x: x1 - r, y: y1 - r), .pi / 2, 0,
                              CGPoint(x: x1, y: y1 - r - arm)),
            .bottomRight: corner(CGPoint(x: x1, y: y0 + r + arm), CGPoint(x: x1, y: y0 + r),
                                 CGPoint(x: x1 - r, y: y0 + r), 0, -.pi / 2,
                                 CGPoint(x: x1 - r - arm, y: y0)),
            .bottomLeft: corner(CGPoint(x: x0 + r + arm, y: y0), CGPoint(x: x0 + r, y: y0),
                                CGPoint(x: x0 + r, y: y0 + r), -.pi / 2, -.pi,
                                CGPoint(x: x0, y: y0 + r + arm)),
        ]
    }

    /// Collapsed, the box is barely taller than its corner radius, so a straight side run would be a
    /// stub. Each side lights its whole rounded cap instead, which is the shape a width drag grabs.
    private static func sideCaps(in frame: NSRect, radius r: CGFloat) -> [Zone: CGPath] {
        let (x0, y0, x1, y1) = (frame.minX, frame.minY, frame.maxX, frame.maxY)
        let arm = min(cornerReach, max(0, (frame.width - 2 * r) / 2))

        // Each cap runs from the top edge, around both arcs on that side, out to the bottom edge.
        // `addArc` draws its own line in from the current point, so only the arms need stating.
        let left = CGMutablePath()
        left.move(to: CGPoint(x: x0 + r + arm, y: y1))
        left.addArc(center: CGPoint(x: x0 + r, y: y1 - r), radius: r,
                    startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        left.addArc(center: CGPoint(x: x0 + r, y: y0 + r), radius: r,
                    startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
        left.addLine(to: CGPoint(x: x0 + r + arm, y: y0))

        let right = CGMutablePath()
        right.move(to: CGPoint(x: x1 - r - arm, y: y1))
        right.addArc(center: CGPoint(x: x1 - r, y: y1 - r), radius: r,
                     startAngle: .pi / 2, endAngle: 0, clockwise: true)
        right.addArc(center: CGPoint(x: x1 - r, y: y0 + r), radius: r,
                     startAngle: 0, endAngle: -.pi / 2, clockwise: true)
        right.addLine(to: CGPoint(x: x1 - r - arm, y: y0))

        return [.left: left, .right: right]
    }

    // MARK: - Test hooks (internal; reached via `@testable import JarvisOverlay`)

    /// Whether the whole-box outline is drawn.
    var isOutlineShown: Bool { outlineLayer.opacity > 0 }

    /// Which zones this box can currently light: all eight, or the two side caps while collapsed.
    var drawableZones: Set<Zone> { Set(runPaths.keys) }
}
