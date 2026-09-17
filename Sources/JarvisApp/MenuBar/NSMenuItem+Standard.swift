import AppKit

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

    func applyStandard(title: String, symbol: String) {
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    }
}
