import Testing
import AppKit
@testable import JarvisOverlay

/// The box has always been resizable, but a borderless window gets no cursor from the window server,
/// so its edges gave no sign they could be dragged. These cover the zone the pointer falls in and the
/// cursor each zone picks.
///
/// AppKit views are not flipped, so y grows upward: the top edge is `maxY`.
@Suite(.serialized) struct OverlayBoxResizeCursorTests {
    private let bounds = NSRect(x: 0, y: 0, width: 520, height: 440)

    @MainActor
    private func zone(_ x: CGFloat, _ y: CGFloat,
                      vertical: Bool = true) -> OverlayBoxResizeCursorView.Zone? {
        OverlayBoxResizeCursorView.zone(
            at: NSPoint(x: x, y: y), in: bounds, allowsVerticalResize: vertical)
    }

    @MainActor @Test
    func theInteriorHasNoResizeZone() {
        #expect(zone(260, 220) == nil)
    }

    @MainActor @Test
    func eachEdgeReportsItsOwnAxis() {
        #expect(zone(260, 438) == .top)
        #expect(zone(260, 2) == .bottom)
        #expect(zone(2, 220) == .left)
        #expect(zone(518, 220) == .right)
    }

    @MainActor @Test
    func eachCornerReportsItsDiagonal() {
        #expect(zone(3, 437) == .topLeft)
        #expect(zone(517, 437) == .topRight)
        #expect(zone(3, 3) == .bottomLeft)
        #expect(zone(517, 3) == .bottomRight)
    }

    /// A corner is reachable from along either edge, not only where the two meet. A 6 pt square would
    /// be hard to hit and would flicker between three cursors as the pointer crossed it.
    @MainActor @Test
    func aCornerIsReachableFromAlongEitherEdge() {
        #expect(zone(2, 430) == .topLeft, "sliding up the left edge into the corner reads as the corner")
        #expect(zone(10, 438) == .topLeft, "sliding left along the top edge into the corner reads as the corner")
    }

    /// Collapsed, the box's height is the header's, so a vertical drag has nothing to do. The
    /// horizontal edges stay live and the corners degrade to them rather than going dead.
    @MainActor @Test
    func aCollapsedBoxOffersOnlyItsHorizontalEdges() {
        #expect(zone(260, 438, vertical: false) == nil, "the top edge goes dead while collapsed")
        #expect(zone(260, 2, vertical: false) == nil, "the bottom edge goes dead while collapsed")
        #expect(zone(2, 220, vertical: false) == .left)
        #expect(zone(2, 438, vertical: false) == .left, "a corner degrades to the edge still worth dragging")
    }

    /// Four axes, four cursors. Corners in particular must not fall back to an edge cursor, which is
    /// what happens if the drawn diagonals fail to build.
    @MainActor @Test
    func eachAxisGetsItsOwnCursor() {
        typealias Zone = OverlayBoxResizeCursorView.Zone
        #expect(Zone.top.cursor === Zone.bottom.cursor, "both vertical edges share one cursor")
        #expect(Zone.left.cursor === Zone.right.cursor, "both horizontal edges share one cursor")
        #expect(Zone.topLeft.cursor === Zone.bottomRight.cursor, "opposite corners share one diagonal")
        #expect(Zone.topRight.cursor === Zone.bottomLeft.cursor, "opposite corners share one diagonal")

        let axes = [Zone.top.cursor, Zone.left.cursor, Zone.topLeft.cursor, Zone.topRight.cursor]
        for (index, cursor) in axes.enumerated() {
            for other in axes[(index + 1)...] {
                #expect(cursor !== other, "the four resize axes must not share a cursor")
            }
        }
    }
}
