import AppKit

extension NSScreen {
    /// Menu titles for the connected displays, in the order `screencapture -D` counts them (main
    /// display first — `screens` uses the same order). The numeric prefix is the `-D` index, and it
    /// keeps titles unique (NSPopUpButton silently drops duplicate titles, e.g. two identical
    /// external monitors). Shared by the Settings → Screen dropdown and the start-time prompt.
    static var displayTitles: [String] {
        screens.enumerated().map { row, screen in
            "\(row + 1): \(screen.localizedName)\(row == 0 ? " (main)" : "")"
        }
    }
}
