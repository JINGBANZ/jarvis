import AppKit

/// Rounded Settings card that lets its owner reflow frame-based content when the window resizes.
///
/// AppKit does not notify a controller when an `NSStackView` changes an arranged view's width. This
/// small outer-edge adapter keeps layout responsibility with the card owner instead of teaching the
/// shared Settings window about any section's internal geometry.
@MainActor
final class SettingsCardView: NSBox {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}
