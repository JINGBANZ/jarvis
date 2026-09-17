import AppKit

/// Draws the resize affordance itself because macOS won't let an inactive app change the cursor,
/// and Jarvis is inactive for the whole session.
final class OverlayBoxResizeAffordanceView: NSView {
    enum Zone: Hashable, CaseIterable {
        case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight
    }

    /// Also the grip thickness, so the ring that refuses a window drag is the ring that resizes.
    static let edgeReach: CGFloat = 6
    private static let cornerReach: CGFloat = 14

    private static let runWidth: CGFloat = 2.5
    private static let runAlpha: CGFloat = 0.9
    private static let runFade: CFTimeInterval = 0.12

    var allowsVerticalResize = true {
        didSet {
            guard allowsVerticalResize != oldValue else { return }
            layoutAffordance()
            if let highlightedZone, runPaths[highlightedZone] == nil { highlight(nil) }
        }
    }

    var onResizeFinished: (() -> Void)?

    private let runLayer = CAShapeLayer()
    private var runPaths: [Zone: CGPath] = [:]
    private(set) var highlightedZone: Zone?
    private var edgeTracking: NSTrackingArea?
    private let topGrip = ResizeGripView()
    private let bottomGrip = ResizeGripView()
    private let leftGrip = ResizeGripView()
    /// Overlaps the scroller knob's outer points on purpose: the window edge belongs to resizing.
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
        // A manually added sublayer animates every `path` change implicitly, so the run would lag a
        // drag. Keyed on `path` alone so the opacity fade stays.
        runLayer.actions = ["path": NSNull()]
        layer?.addSublayer(runLayer)
        for grip in grips {
            grip.owner = self
            addSubview(grip)
        }
        layoutAffordance()
    }

    required init?(coder: NSCoder) { fatalError("built in code; this project has no nibs") }

    /// Never refuse the window drag here: AppKit would apply that to the whole box.
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard let zone = Self.zone(at: local, in: bounds, allowsVerticalResize: allowsVerticalResize)
        else { return nil }
        // Chosen from the zone, not by frame containment: `zone` tests its edges closed while
        // `NSRect.contains` is half-open.
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

    /// AppKit passes the backing scale only to a view's own layer, so this sublayer would blur on
    /// Retina. Also fires when the view joins a window or moves between screens.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        runLayer.contentsScale = window?.backingScaleFactor ?? runLayer.contentsScale
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let edgeTracking { removeTrackingArea(edgeTracking) }
        // `.activeAlways` fires while Jarvis is inactive; `.inVisibleRect` tracks resizes.
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

    /// nil means the pointer has left the box.
    func pointerMoved(to point: NSPoint?) {
        // A drag keeps its run: without `.enabledDuringMouseDrag`, AppKit reports an exit mid-drag
        // but no re-entry until mouse-up.
        guard dragZone == nil else { return }
        // No `bounds.contains` guard: it is half-open where `zone` is closed; `zone` alone decides.
        guard let point else { return highlight(nil) }
        highlight(Self.zone(at: point, in: bounds, allowsVerticalResize: allowsVerticalResize))
    }

    private func highlight(_ zone: Zone?) {
        guard zone != highlightedZone else { return }
        highlightedZone = zone
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

    func beginResize(at point: NSPoint) {
        guard let window,
              let zone = Self.zone(at: point, in: bounds, allowsVerticalResize: allowsVerticalResize)
        else { return }
        dragZone = zone
        // Screen coordinates: the window moves under the pointer, so a window-relative delta
        // would chase itself.
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
        // Tracking was ignored during the drag, so re-read where the pointer actually is.
        if let window {
            pointerMoved(to: convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
        } else {
            pointerMoved(to: nil)
        }
        onResizeFinished?()
    }

    static func resizedFrame(draggingTo pointer: NSPoint, from origin: NSPoint,
                             startFrame: NSRect, zone: Zone,
                             minSize: NSSize, maxSize: NSSize) -> NSRect {
        let delta = CGSize(width: pointer.x - origin.x, height: pointer.y - origin.y)
        var frame = startFrame

        switch zone {
        case .left, .topLeft, .bottomLeft:
            frame.size.width = min(max(startFrame.width - delta.width, minSize.width), maxSize.width)
            frame.origin.x = startFrame.maxX - frame.width
        case .right, .topRight, .bottomRight:
            frame.size.width = min(max(startFrame.width + delta.width, minSize.width), maxSize.width)
        case .top, .bottom:
            break
        }

        switch zone {
        case .bottom, .bottomLeft, .bottomRight:
            frame.size.height = min(max(startFrame.height - delta.height, minSize.height), maxSize.height)
            frame.origin.y = startFrame.maxY - frame.height
        case .top, .topLeft, .topRight:
            frame.size.height = min(max(startFrame.height + delta.height, minSize.height), maxSize.height)
        case .left, .right:
            break
        }

        return frame
    }

    // MARK: - Geometry

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

        // A corner claims the pointer on one of its edges and near the other, so sliding along
        // either edge reaches the diagonal.
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

    /// The box clips to its rounded corners, so the run is inset by half its width plus one point
    /// or it would lose its outer half.
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

    private static func fullRuns(in frame: NSRect, radius r: CGFloat) -> [Zone: CGPath] {
        let (x0, y0, x1, y1) = (frame.minX, frame.minY, frame.maxX, frame.maxY)
        let arm = cornerReach

        func line(_ from: CGPoint, _ to: CGPoint) -> CGPath {
            let path = CGMutablePath()
            path.move(to: from)
            path.addLine(to: to)
            return path
        }
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

    private static func sideCaps(in frame: NSRect, radius r: CGFloat) -> [Zone: CGPath] {
        let (x0, y0, x1, y1) = (frame.minX, frame.minY, frame.maxX, frame.maxY)
        let arm = min(cornerReach, max(0, (frame.width - 2 * r) / 2))

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

    var drawableZones: Set<Zone> { Set(runPaths.keys) }

    var isRunShown: Bool { runLayer.opacity > 0 && runLayer.path != nil }

    var runContentsScale: CGFloat { runLayer.contentsScale }

    /// Reads the suppression, not the behaviour: `action(forKey:)` answers nil both when an action
    /// is suppressed and when CoreAnimation would still supply its default.
    func suppressesImplicitAnimation(of key: String) -> Bool { runLayer.actions?[key] is NSNull }

    func drawsRun(for zone: Zone) -> Bool {
        runLayer.opacity > 0 && runLayer.path != nil && runLayer.path == runPaths[zone]
    }

    var dragBlockingFrames: [NSRect] {
        (mouseDownCanMoveWindow ? [] : [bounds])
            + grips.filter { !$0.mouseDownCanMoveWindow && !$0.frame.isEmpty }.map(\.frame)
    }
}

/// A thin edge strip, because AppKit applies `mouseDownCanMoveWindow == false` to a view's whole
/// frame rather than to what it hit-tests.
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
