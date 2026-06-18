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
/// both learned. The window is rebuilt on each open so sections start fresh (mirrors the viewer's
/// rebuild-on-show pattern).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate, NSTabViewDelegate {
    private let sections: [SettingsSection]
    private var window: NSWindow?
    private var tabView: NSTabView?
    /// The section whose tab is currently selected, so we can pair `didBecomeActive`/`didResignActive`.
    private var activeSection: SettingsSection?

    /// Fixed size for the simple panels; the larger, resizable size for panels that ask for it.
    private static let compactSize = NSSize(width: 560, height: 460)
    private static let expandedSize = NSSize(width: 820, height: 600)
    private static let minResizableSize = NSSize(width: 520, height: 380)

    init(sections: [SettingsSection]) {
        self.sections = sections
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        build()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let win = EscapableWindow(contentRect: NSRect(origin: .zero, size: Self.compactSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Jarvis Settings"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        let tabView = NSTabView(frame: win.contentView!.bounds)
        tabView.autoresizingMask = [.width, .height]
        tabView.delegate = self
        for section in sections {
            let item = NSTabViewItem(identifier: section.title)
            item.label = section.title
            item.view = section.makeView()
            tabView.addTabViewItem(item)
        }
        win.contentView!.addSubview(tabView)
        self.window = win
        self.tabView = tabView
        // Activate the initially-selected tab (delegate callbacks during addTabViewItem above are
        // no-ops because window/tabView weren't wired yet).
        activate(tabView.selectedTabViewItem)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        activate(tabViewItem)
    }

    /// Pair the active/resign hooks and adjust window resizability/size for the newly selected tab.
    private func activate(_ item: NSTabViewItem?) {
        guard let item, let tabView, let win = window else { return }
        let idx = tabView.indexOfTabViewItem(item)
        guard sections.indices.contains(idx) else { return }
        let newly = sections[idx]
        guard newly !== activeSection else { return }
        activeSection?.didResignActive()
        activeSection = newly
        applyWindowSizing(for: newly, window: win)
        newly.didBecomeActive()
    }

    private func applyWindowSizing(for section: SettingsSection, window win: NSWindow) {
        if section.prefersResizableWindow {
            win.styleMask.insert(.resizable)
            win.minSize = Self.minResizableSize
            win.setContentSize(Self.expandedSize)
        } else {
            win.styleMask.remove(.resizable)
            win.setContentSize(Self.compactSize)
        }
    }

    func windowWillClose(_ notification: Notification) {
        activeSection?.didResignActive()        // e.g. turn the overlay preview off if Overlay was open
        activeSection = nil
        for section in sections { section.windowWillClose() }
        NSApp.setActivationPolicy(.accessory)   // back to menu-bar-only
        window = nil
        tabView = nil
    }
}
