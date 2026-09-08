import AppKit

/// A transparent sheet over the Overlay Box that draws its resize affordance and owns the drag.
///
/// The panel has always been resizable, but a borderless window has no chrome to advertise it. The
/// obvious answer, a resize cursor, is not available: macOS refuses to let an inactive application
/// change the cursor, and Jarvis is a background app for all of a session, so a cursor would appear
/// only in the one state where Settings happens to be open. Apple's own `screencapture` reaches for
/// private SkyLight calls to get around that, which is not a dependency worth taking for a cursor.
/// So the panel draws the affordance itself: the edge or corner under the pointer lights up.
///
/// The events, unlike the cursor, do arrive while inactive. One `.activeAlways` tracking area is
/// enough, and this view turns the pointer's position into one of eight zones.
///
/// The drag belongs here too, so the region that lights and the region that resizes are one region.
/// That is what `ResizeGripView` is for: AppKit applies `mouseDownCanMoveWindow == false` to a view's
/// entire frame rather than to what it hit-tests, so this full-size view refusing the drag would
/// freeze the whole box in place. The grips are thin strips along the edges, so only the ring that
/// resizes refuses to move, and a drag anywhere else still moves the box.
final class OverlayBoxResizeAffordanceView: NSView {
    /// Which edge or corner of the box the pointer is over.
    enum Zone: Hashable, CaseIterable {
        case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight
    }

    /// How close to an edge the pointer must be for that edge to claim it. Also the thickness of the
    /// grips, so the ring that refuses a window drag is exactly the ring that resizes.
    static let edgeReach: CGFloat = 6
    /// How far along an edge a corner still claims the pointer.
    private static let cornerReach: CGFloat = 14

    private static let runWidth: CGFloat = 2.5
    private static let runAlpha: CGFloat = 0.9
    private static let runFade: CFTimeInterval = 0.12

    /// Collapsed, the box's height is the header's, so a vertical drag has nothing to do.
    var allowsVerticalResize = true {
        didSet {
            guard allowsVerticalResize != oldValue else { return }
            layoutAffordance()
            // The run under the pointer may have just become undraggable.
            if let highlightedZone, runPaths[highlightedZone] == nil { highlight(nil) }
        }
    }

    /// Reports the end of a resize drag, so the panel can persist the size the user settled on. The
    /// panel's own `viewDidEndLiveResize` never fires for these: AppKit is not the one resizing.
    var onResizeFinished: (() -> Void)?

    private let runLayer = CAShapeLayer()
    private var runPaths: [Zone: CGPath] = [:]
    private(set) var highlightedZone: Zone?
    private var edgeTracking: NSTrackingArea?
    private let topGrip = ResizeGripView()
    private let bottomGrip = ResizeGripView()
    private let leftGrip = ResizeGripView()
    /// The box's overlay scroller sits flush against this edge, so the outer few points of its knob
    /// fall inside this strip and resize instead of scrolling. The same trade-off the header buttons
    /// make: the extreme edge of the window belongs to resizing.
    private let rightGrip = ResizeGripView()
    private var grips: [ResizeGripView] { [topGrip, bottomGrip, leftGrip, rightGrip] }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        runLayer.fillColor = nil
        runLayer.strokeColor = NSColor(white: 1, alpha: Self.runAlpha).cgColor
        runLayer.lineWidth = Self.runWidth
        runLayer.lineCap = .round
        runLayer.opacity = 0
        // AppKit suppresses implicit CoreAnimation actions only for a view's *own* backing layer,
        // through its delegate. This is a manually added sublayer with no delegate, so CoreAnimation
        // supplies its default quarter-second animation for every `path` assignment: the lit run would
        // interpolate toward the edge instead of tracking it through a drag, and morphing between an
        // edge run and a corner run is undefined anyway, their paths having different element counts.
        // Keyed on `path` alone, so the opacity fade in `fade(to:)` stays.
        runLayer.actions = ["path": NSNull()]
        layer?.addSublayer(runLayer)
        for grip in grips {
            grip.owner = self
            addSubview(grip)
        }
        layoutAffordance()
    }

    required init?(coder: NSCoder) { fatalError("built in code; this project has no nibs") }

    /// This view must never refuse the window drag: AppKit would apply that to its whole frame, which
    /// is the whole box. Only the grips refuse it, and only over the edges they cover.
    override var mouseDownCanMoveWindow: Bool { true }

    /// Claim exactly the zones this view lights, and nothing else. The press is handed to the grip
    /// covering that edge, which is the view whose frame tells AppKit not to move the window there.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard let zone = Self.zone(at: local, in: bounds, allowsVerticalResize: allowsVerticalResize)
        else { return nil }
        // Chosen from the zone, not by frame containment: `zone` tests its edges closed while
        // `NSRect.contains` is half-open, so at exactly `x == edgeReach` no grip contained the point
        // and a lit column fell through and moved the box instead of resizing it.
        return grip(for: zone)
    }

    private func grip(for zone: Zone) -> ResizeGripView {
        switch zone {
        case .top, .topLeft, .topRight: topGrip
        case .bottom, .bottomLeft, .bottomRight: bottomGrip
        case .left: leftGrip
        case .right: rightGrip
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutAffordance()
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
        // A drag keeps the run it started on. The tracking area has no `.enabledDuringMouseDrag`, so
        // AppKit still reports `mouseExited` mid-drag but will not report entering again until
        // mouse-up: an outward drag would otherwise go dark the moment the pointer outran the frame,
        // while an inward one stayed lit.
        guard dragZone == nil else { return }
        guard let point, bounds.contains(point) else { return highlight(nil) }
        highlight(Self.zone(at: point, in: bounds, allowsVerticalResize: allowsVerticalResize))
    }

    private func highlight(_ zone: Zone?) {
        guard zone != highlightedZone else { return }
        highlightedZone = zone
        // Swapping the path outright rather than cross-fading two layers: adjacent runs are 120 ms
        // apart, and a moment with both lit would read as a glitch rather than as a transition.
        if let zone, let path = runPaths[zone] {
            runLayer.path = path
            fade(to: 1)
        } else {
            fade(to: 0)
        }
    }

    private func fade(to opacity: Float) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Self.runFade)
        runLayer.opacity = opacity
        CATransaction.commit()
    }

    // MARK: - Dragging

    private var dragZone: Zone?
    private var dragStartPointer: NSPoint = .zero
    private var dragStartFrame: NSRect = .zero

    /// Called by whichever grip took the press.
    func beginResize(at point: NSPoint) {
        guard let window,
              let zone = Self.zone(at: point, in: bounds, allowsVerticalResize: allowsVerticalResize)
        else { return }
        dragZone = zone
        // Screen coordinates throughout: the window's frame moves under the pointer as it is dragged,
        // so a window-relative delta would chase itself.
        dragStartPointer = NSEvent.mouseLocation
        dragStartFrame = window.frame
    }

    func continueResize() {
        guard let zone = dragZone, let window else { return }
        window.setFrame(Self.resizedFrame(draggingTo: NSEvent.mouseLocation,
                                          from: dragStartPointer,
                                          startFrame: dragStartFrame,
                                          zone: zone,
                                          minSize: window.minSize,
                                          maxSize: window.maxSize),
                        display: true)
    }

    func endResize() {
        guard dragZone != nil else { return }
        dragZone = nil
        // The pointer may have ended the drag well outside the box, so re-read where it actually is
        // rather than leaving the run lit on an edge nobody is touching.
        if let window {
            pointerMoved(to: convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
        } else {
            pointerMoved(to: nil)
        }
        onResizeFinished?()
    }

    /// The frame a drag lands on: the dragged edge follows the pointer, the opposite edge stays put,
    /// and the window's own declared limits are the floor and ceiling, so they remain the single
    /// source of the box's size range.
    static func resizedFrame(draggingTo pointer: NSPoint, from origin: NSPoint,
                             startFrame: NSRect, zone: Zone,
                             minSize: NSSize, maxSize: NSSize) -> NSRect {
        let delta = CGSize(width: pointer.x - origin.x, height: pointer.y - origin.y)
        var frame = startFrame

        switch zone {
        case .left, .topLeft, .bottomLeft:
            frame.size.width = min(max(startFrame.width - delta.width, minSize.width), maxSize.width)
            frame.origin.x = startFrame.maxX - frame.width   // the right edge is anchored
        case .right, .topRight, .bottomRight:
            frame.size.width = min(max(startFrame.width + delta.width, minSize.width), maxSize.width)
        case .top, .bottom:
            break
        }

        switch zone {
        case .bottom, .bottomLeft, .bottomRight:
            frame.size.height = min(max(startFrame.height - delta.height, minSize.height), maxSize.height)
            frame.origin.y = startFrame.maxY - frame.height  // the top edge is anchored
        case .top, .topLeft, .topRight:
            frame.size.height = min(max(startFrame.height + delta.height, minSize.height), maxSize.height)
        case .left, .right:
            break
        }

        return frame
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

    private func layoutAffordance() {
        placeGrips()
        rebuildPaths()
    }

    /// Four strips whose union is the resizable ring. The vertical pair collapses to nothing when the
    /// box is rolled up, so those edges neither resize nor block a drag.
    private func placeGrips() {
        let reach = Self.edgeReach
        let (w, h) = (bounds.width, bounds.height)
        topGrip.frame = allowsVerticalResize
            ? NSRect(x: 0, y: h - reach, width: w, height: reach) : .zero
        bottomGrip.frame = allowsVerticalResize
            ? NSRect(x: 0, y: 0, width: w, height: reach) : .zero
        leftGrip.frame = NSRect(x: 0, y: 0, width: reach, height: h)
        rightGrip.frame = NSRect(x: w - reach, y: 0, width: reach, height: h)
    }

    /// The panel clips to its rounded corners (`box.layer.masksToBounds`), so a stroke centred on the
    /// box's edge would lose its outer half. The run is inset by its half-width plus one point, which
    /// puts the whole stroke inside the clip and reads as a hairline just within the edge.
    private func rebuildPaths() {
        let inset = Self.runWidth / 2 + 1
        let frame = bounds.insetBy(dx: inset, dy: inset)
        guard frame.width > 2 * OverlayBoxChrome.cornerRadius, frame.height > 0 else {
            runLayer.path = nil
            runPaths = [:]
            return
        }
        runPaths = allowsVerticalResize
            ? Self.fullRuns(in: frame, radius: OverlayBoxChrome.cornerRadius - inset)
            : Self.sideCaps(in: frame, radius: OverlayBoxChrome.cornerRadius - inset)
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
        func corner(_ start: CGPoint, _ center: CGPoint,
                    _ from: CGFloat, _ to: CGFloat, _ end: CGPoint) -> CGPath {
            let path = CGMutablePath()
            path.move(to: start)
            path.addArc(center: center, radius: r, startAngle: from, endAngle: to, clockwise: true)
            path.addLine(to: end)
            return path
        }

        return [
            .top: line(CGPoint(x: x0 + r + arm, y: y1), CGPoint(x: x1 - r - arm, y: y1)),
            .bottom: line(CGPoint(x: x0 + r + arm, y: y0), CGPoint(x: x1 - r - arm, y: y0)),
            .left: line(CGPoint(x: x0, y: y0 + r + arm), CGPoint(x: x0, y: y1 - r - arm)),
            .right: line(CGPoint(x: x1, y: y0 + r + arm), CGPoint(x: x1, y: y1 - r - arm)),
            .topLeft: corner(CGPoint(x: x0, y: y1 - r - arm), CGPoint(x: x0 + r, y: y1 - r),
                             .pi, .pi / 2, CGPoint(x: x0 + r + arm, y: y1)),
            .topRight: corner(CGPoint(x: x1 - r - arm, y: y1), CGPoint(x: x1 - r, y: y1 - r),
                              .pi / 2, 0, CGPoint(x: x1, y: y1 - r - arm)),
            .bottomRight: corner(CGPoint(x: x1, y: y0 + r + arm), CGPoint(x: x1 - r, y: y0 + r),
                                 0, -.pi / 2, CGPoint(x: x1 - r - arm, y: y0)),
            .bottomLeft: corner(CGPoint(x: x0 + r + arm, y: y0), CGPoint(x: x0 + r, y: y0 + r),
                                -.pi / 2, -.pi, CGPoint(x: x0, y: y0 + r + arm)),
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

    /// Which zones this box can currently light: all eight, or the two side caps while collapsed.
    var drawableZones: Set<Zone> { Set(runPaths.keys) }

    /// Whether a run is drawn right now.
    var isRunShown: Bool { runLayer.opacity > 0 && runLayer.path != nil }

    /// Whether a change to `key` on the run's layer is set to land at once.
    ///
    /// It reports the suppression rather than the resulting behaviour: `action(forKey:)` cannot tell
    /// the two apart, answering nil both where an action is suppressed and where CoreAnimation would
    /// still supply its own built-in default for an animatable property.
    func suppressesImplicitAnimation(of key: String) -> Bool { runLayer.actions?[key] is NSNull }

    /// Whether the run actually drawn is the one belonging to `zone`. `highlightedZone` only reports
    /// what the zone lookup returned; this proves the matching geometry reached the layer.
    func drawsRun(for zone: Zone) -> Bool {
        runLayer.opacity > 0 && runLayer.path != nil && runLayer.path == runPaths[zone]
    }

    /// The regions this view and its grips use to tell AppKit not to move the window. Each must stay a
    /// thin edge strip: AppKit applies the refusal to a view's whole frame, so anything larger freezes
    /// the box. (The header's buttons refuse it too, by `NSControl` default, but they are the header's
    /// business and sit well inside it.)
    var dragBlockingFrames: [NSRect] {
        (mouseDownCanMoveWindow ? [] : [bounds])
            + grips.filter { !$0.mouseDownCanMoveWindow && !$0.frame.isEmpty }.map(\.frame)
    }
}

/// A strip along one edge of the box, thick enough to grab and no thicker.
///
/// It exists because AppKit applies `mouseDownCanMoveWindow == false` to a view's entire frame rather
/// than to what it hit-tests. The full-size affordance view refusing the drag therefore froze the
/// whole box; these strips refuse it only over the ring that actually resizes.
private final class ResizeGripView: NSView {
    weak var owner: OverlayBoxResizeAffordanceView?

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let owner else { return }
        owner.beginResize(at: owner.convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) { owner?.continueResize() }
    override func mouseUp(with event: NSEvent) { owner?.endResize() }
}
