import AppKit

/// The one standard format for items in the Jarvis menu-bar menu: an SF Symbol icon followed by the
/// title. Build every item through `standard(...)` — and restyle mutable ones with `applyStandard` —
/// so new entries automatically match; never hand-construct a bare `NSMenuItem` for the menu.
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
