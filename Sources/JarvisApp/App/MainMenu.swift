import AppKit

/// The app's main menu bar. A menu-bar (`LSUIElement`) app installs no main menu by default, which
/// means the standard editing shortcuts (⌘X / ⌘C / ⌘V / ⌘A) have no menu items to dispatch them — so
/// they silently do nothing in the Settings text fields (paste fails). Installing a minimal menu with
/// an Edit submenu restores them: AppKit resolves the shortcuts against the main menu and routes the
/// responder-chain selectors to whatever field editor is first responder.
enum MainMenu {
    @MainActor
    static func install() {
        let mainMenu = NSMenu()

        // First slot is always the application menu (system shows it titled with the app name). Holds
        // Quit so ⌘Q works while the Settings window is focused.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // The reason this menu exists: standard editing commands, targeting the first responder via the
        // responder chain (nil target).
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }
}
