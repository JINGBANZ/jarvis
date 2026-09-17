import AppKit

// Design: wiki/settings-window.md
/// Promotes the accessory app to `.regular` while open, because text fields in an accessory app
/// can't become first responder or accept paste.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate, NSTabViewDelegate {
    private let sections: [SettingsSection]
    private var window: NSWindow?
    private var tabView: NSTabView?
    private var loadedSectionIndexes: Set<Int> = []
    private var activeSection: SettingsSection?

    /// Shared by every tab, because per-tab sizes made the window jump on each tab switch.
    private static let defaultContentSize = NSSize(width: 820, height: 600)
    private static let minContentSize = NSSize(width: 560, height: 460)

    init(sections: [SettingsSection]) {
        self.sections = sections
    }

    func show() {
        NSApp.setActivationPolicy(.regular) // ghost-mode-allowed: explicit Settings action
        if window == nil { build() }
        activate(tabView?.selectedTabViewItem)
        NSApp.activate(ignoringOtherApps: true) // ghost-mode-allowed: explicit Settings action
        window?.makeKeyAndOrderFront(nil) // ghost-mode-allowed: explicit Settings action
    }

    private func build() {
        let win = EscapableWindow(contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Jarvis Settings"
        win.isReleasedWhenClosed = false
        win.contentMinSize = Self.minContentSize
        win.delegate = self
        win.center()

        let tabView = NSTabView(frame: win.contentView!.bounds)
        tabView.autoresizingMask = [.width, .height]
        tabView.delegate = self
        for section in sections {
            let item = NSTabViewItem(identifier: section.title)
            item.label = section.title
            item.view = NSView()
            tabView.addTabViewItem(item)
        }
        win.contentView!.addSubview(tabView)
        self.window = win
        self.tabView = tabView
    }

    private static func topPinned(_ view: NSView) -> NSView {
        let container = NSView(frame: view.frame)
        // Flexible bottom and side margins: pinned top, centered horizontally.
        view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        container.addSubview(view)
        return container
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        activate(tabViewItem)
    }

    private func activate(_ item: NSTabViewItem?) {
        guard let item, let tabView else { return }
        let idx = tabView.indexOfTabViewItem(item)
        guard sections.indices.contains(idx) else { return }
        let newly = sections[idx]
        guard newly !== activeSection else { return }
        activeSection?.didResignActive()
        if loadedSectionIndexes.insert(idx).inserted {
            let view = newly.makeView()
            item.view = newly.fillsTab ? view : Self.topPinned(view)
        }
        activeSection = newly
        newly.didBecomeActive()
    }

    func windowWillClose(_ notification: Notification) {
        activeSection?.didResignActive()
        activeSection = nil
        for section in sections { section.windowWillClose() }
        // Keep the window shell but release every section view, so controls and Activity's WebView
        // start fresh on the next open.
        tabView?.delegate = nil
        for item in tabView?.tabViewItems ?? [] { item.view = NSView() }
        loadedSectionIndexes.removeAll()
        tabView?.selectTabViewItem(at: 0)
        tabView?.delegate = self
        NSApp.setActivationPolicy(.accessory) // ghost-mode-allowed: close explicit Settings action
    }
}
