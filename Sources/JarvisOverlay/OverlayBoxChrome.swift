import CoreGraphics

/// Scales with the box's height. The title deliberately ignores the Settings text-size slider,
/// which sizes only the tips.
struct OverlayBoxChrome: Equatable {
    /// Shared by the panel's rounded fill and the affordance's corner runs, which must agree.
    static let cornerRadius: CGFloat = 12

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
