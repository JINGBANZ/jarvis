import Testing
import AppKit
@testable import JarvisOverlay

/// The box has always been resizable, but a borderless window gives no sign of it. macOS refuses to
/// let an inactive app set the cursor, and Jarvis is a background app for all of an interview, so the
/// panel draws the affordance itself: an outline while the pointer is anywhere inside, and a brighter
/// run on whichever edge or corner it is over.
///
/// AppKit views are not flipped, so y grows upward: the top edge is `maxY`.
@Suite(.serialized) struct OverlayBoxResizeAffordanceTests {
    private let bounds = NSRect(x: 0, y: 0, width: 520, height: 440)

    @MainActor
    private func zone(_ x: CGFloat, _ y: CGFloat,
                      vertical: Bool = true) -> OverlayBoxResizeAffordanceView.Zone? {
        OverlayBoxResizeAffordanceView.zone(
            at: NSPoint(x: x, y: y), in: bounds, allowsVerticalResize: vertical)
    }

    @MainActor
    private func view(collapsed: Bool = false) -> OverlayBoxResizeAffordanceView {
        let view = OverlayBoxResizeAffordanceView(frame: bounds)
        view.allowsVerticalResize = !collapsed
        return view
    }

    // MARK: - Zones

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
    /// be hard to hit and would flicker between three runs as the pointer crossed it.
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

    // MARK: - What gets drawn

    /// The outline answers "can this be resized at all", which is the question a cursor never got to
    /// answer here. It shows for the whole box, not just its edges.
    @MainActor @Test
    func thePointerInsideTheBoxShowsTheOutline() {
        let view = view()
        #expect(!view.isOutlineShown, "an untouched box draws nothing")

        view.pointerMoved(to: NSPoint(x: 260, y: 220))   // deep interior

        #expect(view.isOutlineShown)
        #expect(view.highlightedZone == nil, "the interior lights no run")
    }

    @MainActor @Test
    func thePointerOnAnEdgeHighlightsThatRun() {
        let view = view()
        view.pointerMoved(to: NSPoint(x: 518, y: 220))
        #expect(view.highlightedZone == .right)
        #expect(view.isOutlineShown, "the outline stays up under the highlighted run")

        view.pointerMoved(to: NSPoint(x: 517, y: 437))
        #expect(view.highlightedZone == .topRight, "moving into the corner swaps the run")
    }

    @MainActor @Test
    func thePointerLeavingClearsEverything() {
        let view = view()
        view.pointerMoved(to: NSPoint(x: 518, y: 220))
        view.pointerMoved(to: nil)
        #expect(!view.isOutlineShown, "nothing is left drawn on a box you are not touching")
        #expect(view.highlightedZone == nil)
    }

    /// The affordance only exists where a drag can do something, so a collapsed box draws two runs,
    /// not eight.
    @MainActor @Test
    func aCollapsedBoxDrawsOnlyItsSideRuns() {
        #expect(view(collapsed: false).drawableZones
            == Set(OverlayBoxResizeAffordanceView.Zone.allCases))
        #expect(view(collapsed: true).drawableZones == [.left, .right])
    }

    /// Collapsing while the pointer sits on the top edge must not leave a run lit over an axis that
    /// can no longer be dragged.
    @MainActor @Test
    func collapsingClearsARunThatJustWentDead() {
        let view = view()
        view.pointerMoved(to: NSPoint(x: 260, y: 438))
        #expect(view.highlightedZone == .top)

        view.allowsVerticalResize = false

        #expect(view.highlightedZone == nil)
    }

    /// It must never intercept a click: the header's buttons sit underneath it, and a drag anywhere on
    /// the box moves the window.
    @MainActor @Test
    func itTakesNoPartInHitTesting() {
        #expect(view().hitTest(NSPoint(x: 260, y: 220)) == nil)
        #expect(view().hitTest(NSPoint(x: 2, y: 220)) == nil, "not even on an edge it draws")
    }
}
