import AppKit

/// The one standard format for commands in the Jarvis menu-bar menu: an SF Symbol icon followed by
/// the title. Build every command through `standard(...)` — and restyle mutable ones with
/// `applyStandard` — so new entries automatically match; never hand-construct a bare `NSMenuItem` for
/// a command. The footer version caption is the sole exception: it is not a command, and centering it
/// needs a custom item view (see `MenuBarController.versionItem()`).
@MainActor
extension NSMenuItem {
    static func standard(_ title: String, symbol: String,
                         action: Selector? = nil, target: AnyObject? = nil,
                         keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        item.applyStandard(title: title, symbol: symbol)
        return item
    }

    /// Restyle an existing item in place — for items whose title/icon change at runtime
    /// (e.g. Start ↔ Stop).
    func applyStandard(title: String, symbol: String) {
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    }
}
