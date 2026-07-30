import AppKit
import JarvisCore

/// Settings panel that embeds the live activity viewer inside the common page and card shell.
/// The viewer still owns all WKWebView/session/live-append logic and lifecycle.
@MainActor
final class ActivitySection: NSObject, SettingsSection {
    let title = "Activity"

    private let viewer: ActivityViewer

    init(viewer: ActivityViewer) {
        self.viewer = viewer
    }

    func makeView() -> NSView {
        let viewerContent = viewer.makeContentView()
        let card = SettingsCardView(
            frame: NSRect(x: 0, y: 0, width: 712, height: 432))
        card.contentView?.addSubview(viewerContent)
        card.onLayout = { [weak card, weak viewerContent] in
            guard let card, let viewerContent else { return }
            viewerContent.frame = card.contentView?.bounds ?? card.bounds
        }
        card.onLayout?()
        return SettingsPageView(
            title: "Activity",
            summary: "Review the human-facing record of your coaching sessions.",
            bodyView: card)
    }
    func didBecomeActive() { viewer.didBecomeActive() }
    func windowWillClose() { viewer.teardown() }

    /// The embedded viewer stretches with the window, unlike the fixed-form panels.
    var fillsTab: Bool { true }
}
