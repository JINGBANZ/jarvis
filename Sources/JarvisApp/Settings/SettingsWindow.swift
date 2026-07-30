import AppKit

/// A titled settings window that also closes on Escape (and Cmd-.), matching the dismissal the old
/// API-key modal offered and standard macOS settings-window behavior. A plain `NSWindow` ignores
/// `cancelOperation(_:)`.
private final class EscapableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// One window hosting all settings sections as tabs. Non-modal: it promotes the accessory app to
/// `.regular` while open (so secure/text fields can become first responder and accept paste) and
/// drops back to `.accessory` on close — the lesson the old API-key dialog and activity viewer
/// both learned. The lightweight window/tab shell is retained between opens, while section views are
/// rebuilt lazily so controls start fresh without constructing hidden tabs before presentation.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate, NSTabViewDelegate {
    private let sections: [SettingsSection]
    private var window: NSWindow?
    private var tabView: NSTabView?
    private var loadedSectionIndexes: Set<Int> = []
    /// The section whose tab is currently selected, so we can pair `didBecomeActive`/`didResignActive`.
    private var activeSection: SettingsSection?

    /// One size for every tab — switching tabs must never resize the window (per-tab sizes made it
    /// jump on each switch). The user can still resize freely down to `minContentSize`, which keeps
    /// the shared page shell and responsive trailing controls usable.
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

    /// Compatibility wrapper for a future compact fixed-layout section. The four built-in sections
    /// fill the tab through `SettingsPageView`.
    private static func topPinned(_ view: NSView) -> NSView {
        let container = NSView(frame: view.frame)
        // Flexible bottom + equal flexible side margins: pinned top, centered horizontally.
        view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        container.addSubview(view)
        return container
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        activate(tabViewItem)
    }

    /// Pair the active/resign hooks for the newly selected tab.
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
        activeSection?.didResignActive()        // e.g. turn the overlay preview off if Overlay was open
        activeSection = nil
        for section in sections { section.windowWillClose() }
        // Preserve the cheap NSWindow/NSTabView shell, but release every section view so controls and
        // Activity's WebView still get their established fresh-on-open lifecycle.
        tabView?.delegate = nil
        for item in tabView?.tabViewItems ?? [] { item.view = NSView() }
        loadedSectionIndexes.removeAll()
        tabView?.selectTabViewItem(at: 0)
        tabView?.delegate = self
        NSApp.setActivationPolicy(.accessory) // ghost-mode-allowed: close explicit Settings action
    }
}
