import AppKit
import JarvisCore

/// Settings panel that embeds the live activity viewer. Thin wrapper: the viewer owns all
/// WKWebView/session/live-append logic; this just vends its content view into a tab and tears it
/// down on close.
@MainActor
final class ActivitySection: NSObject, SettingsSection {
    let title = "Activity"

    private let viewer: ActivityViewer

    init(viewer: ActivityViewer) {
        self.viewer = viewer
    }

    func makeView() -> NSView { viewer.makeContentView() }
    func windowWillClose() { viewer.teardown() }

    /// The embedded viewer stretches with the window, unlike the fixed-form panels.
    var fillsTab: Bool { true }
}
