import AppKit

/// Only the current view takes clicks: AppKit hit-tests by frame and ignores layer opacity and
/// transform, so a page fading out would swallow clicks meant for the hub.
@MainActor
final class SettingsPageContainer: NSView {
    weak var currentView: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit, let currentView, hit !== self, !hit.isDescendant(of: currentView) else {
            return hit
        }
        // `hitTest` takes a point in the receiver's superview, which for the current view is this one.
        return currentView.hitTest(convert(point, from: superview)) ?? self
    }
}
