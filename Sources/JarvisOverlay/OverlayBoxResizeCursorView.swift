import AppKit

/// A transparent sheet over the Overlay Box that gives its edges a resize cursor.
///
/// The panel has always been resizable, but a borderless window has no chrome for the window server
/// to hang a resize cursor on, so the edges looked inert. `resetCursorRects` is not the tool here:
/// AppKit maintains cursor rects only for the key window, and this is a nonactivating panel that
/// never becomes key. One `.activeAlways` tracking area receives mouse-moved events regardless, and
/// this view turns the pointer's position into one of eight zones.
///
/// It takes no part in hit testing, so clicks still reach the header buttons underneath and a drag
/// anywhere still moves the window.
final class OverlayBoxResizeCursorView: NSView {
    /// Which edge or corner of the box the pointer is over.
    enum Zone: Equatable {
        case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight
    }

    /// How close to an edge the pointer must be for that edge to claim it.
    private static let edgeReach: CGFloat = 6
    /// How far along an edge a corner still claims the pointer.
    private static let cornerReach: CGFloat = 14

    /// Collapsed, the box's height is the header's, so a vertical drag has nothing to do.
    var allowsVerticalResize = true {
        didSet {
            guard allowsVerticalResize != oldValue else { return }
            show(nil)   // whatever the pointer was over may have just gone dead
        }
    }

    private var currentZone: Zone?
    private var edgeTracking: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let edgeTracking { removeTrackingArea(edgeTracking) }
        // `.inVisibleRect` keeps the area matched to the view as the box is dragged wider or taller,
        // which is exactly when the edges move (the `rect` is then ignored).
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self)
        addTrackingArea(area)
        edgeTracking = area
    }

    override func mouseMoved(with event: NSEvent) { follow(event) }
    override func mouseEntered(with event: NSEvent) { follow(event) }
    override func mouseExited(with event: NSEvent) { show(nil) }

    private func follow(_ event: NSEvent) {
        show(Self.zone(at: convert(event.locationInWindow, from: nil),
                       in: bounds,
                       allowsVerticalResize: allowsVerticalResize))
    }

    /// Only on a change: setting the cursor on every mouse-moved event fights AppKit's own updates.
    private func show(_ zone: Zone?) {
        guard zone != currentZone else { return }
        currentZone = zone
        (zone?.cursor ?? .arrow).set()
    }

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
}

extension OverlayBoxResizeCursorView.Zone {
    @MainActor var cursor: NSCursor {
        switch self {
        case .top, .bottom: OverlayBoxResizeCursors.vertical
        case .left, .right: OverlayBoxResizeCursors.horizontal
        case .topLeft, .bottomRight: OverlayBoxResizeCursors.downwardDiagonal
        case .topRight, .bottomLeft: OverlayBoxResizeCursors.upwardDiagonal
        }
    }
}

/// The four resize cursors, built once.
///
/// AppKit publishes no diagonal resize cursor at this project's deployment target, so the corners
/// rotate the stock vertical one: they then match every other resize cursor on the system instead of
/// looking like a drawing of one.
@MainActor
private enum OverlayBoxResizeCursors {
    static let vertical = NSCursor.resizeUpDown
    static let horizontal = NSCursor.resizeLeftRight
    static let downwardDiagonal = rotatedResizeCursor(degrees: -45)   // ↖↘
    static let upwardDiagonal = rotatedResizeCursor(degrees: 45)      // ↗↙

    private static func rotatedResizeCursor(degrees: CGFloat) -> NSCursor {
        let source = NSCursor.resizeUpDown.image
        let unrotated = { NSCursor(image: source, hotSpot: NSPoint(x: source.size.width / 2,
                                                                   y: source.size.height / 2)) }
        // Rotating a glyph inside its own bounds clips its points, so draw onto a square large enough
        // to hold the diagonal.
        let side = (max(source.size.width, source.size.height) * 1.5).rounded(.up)
        let pixelScale = 2   // cursor art ships at 2x; the rep's point size below keeps it its own size
        guard side > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(side) * pixelScale, pixelsHigh: Int(side) * pixelScale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return unrotated() }
        rep.size = NSSize(width: side, height: side)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return unrotated() }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let spin = NSAffineTransform()
        spin.translateX(by: side / 2, yBy: side / 2)
        spin.rotate(byDegrees: degrees)
        spin.translateX(by: -side / 2, yBy: -side / 2)
        spin.concat()
        source.draw(in: NSRect(x: (side - source.size.width) / 2,
                               y: (side - source.size.height) / 2,
                               width: source.size.width, height: source.size.height))
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}
