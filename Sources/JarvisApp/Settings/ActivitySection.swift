import AppKit
import JarvisCore

/// Settings → Activity: embeds the live activity viewer inside the common page and card shell, where
/// it stretches with the window. The viewer still owns all WKWebView/session/live-append logic and
/// lifecycle.
@MainActor
final class ActivitySection: NSObject, SettingsSection {
    let destination = SettingsDestination.activity

    private let viewer: ActivityViewer

    init(viewer: ActivityViewer) {
        self.viewer = viewer
    }

    func makePage() -> SettingsPageView {
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
            summary: "What I heard and said, session by session.",
            bodyView: card)
    }
    func didBecomeActive() { viewer.didBecomeActive() }
    func windowWillClose() { viewer.teardown() }
}
