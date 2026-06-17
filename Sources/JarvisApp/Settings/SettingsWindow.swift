import AppKit

/// One window hosting all settings sections as tabs. Non-modal: it promotes the accessory app to
/// `.regular` while open (so secure/text fields can become first responder and accept paste) and
/// drops back to `.accessory` on close — the lesson the old API-key dialog and activity viewer
/// both learned. The window is rebuilt on each open so sections start fresh (mirrors the viewer's
/// rebuild-on-show pattern).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let sections: [SettingsSection]
    private var window: NSWindow?

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
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Jarvis Settings"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        let tabView = NSTabView(frame: win.contentView!.bounds)
        tabView.autoresizingMask = [.width, .height]
        for section in sections {
            let item = NSTabViewItem(identifier: section.title)
            item.label = section.title
            item.view = section.makeView()
            tabView.addTabViewItem(item)
        }
        win.contentView!.addSubview(tabView)
        self.window = win
    }

    func windowWillClose(_ notification: Notification) {
        for section in sections { section.windowWillClose() }
        NSApp.setActivationPolicy(.accessory)   // back to menu-bar-only
        window = nil
    }
}
