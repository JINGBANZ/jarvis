import CoreGraphics

/// The Overlay Box header's geometry, derived from the box's content height.
///
/// The box is the one surface the user sizes directly, anywhere from a 140 pt strip to a full
/// display, so a fixed header would eat a fifth of a small box and read as a hairline on a large one.
/// Every dimension here is a fraction of the box's height and then clamped: the lower bounds keep the
/// buttons aimable, the upper bounds keep the strip reading as chrome rather than as a banner.
///
/// The title tracks the header rather than the Settings text-size slider, so that slider keeps
/// meaning "how big are the tips".
struct OverlayBoxChrome: Equatable {
    /// Height of the header strip, and so the height of the whole panel while collapsed.
    let height: CGFloat
    let titlePointSize: CGFloat
    let iconPointSize: CGFloat
    /// Side of the square button drawn behind each icon.
    let button: CGFloat
    /// Gap between a button and the box's edge.
    let inset: CGFloat

    init(contentHeight: CGFloat) {
        height = min(max((contentHeight * 0.075).rounded(), 26), 44)
        titlePointSize = min(max((height * 0.44).rounded(), 11), 19)
        iconPointSize = (height * 0.5).rounded()
        button = height - 8
        inset = (height * 0.17).rounded()
    }
}
