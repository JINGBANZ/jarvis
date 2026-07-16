import AppKit

extension NSScreen {
    /// Menu titles for the connected displays, in the order `screencapture -D` counts them (main
    /// display first — `screens` uses the same order). The numeric prefix is the `-D` index, and it
    /// keeps titles unique (NSPopUpButton silently drops duplicate titles, e.g. two identical
    /// external monitors). Used by the Settings → Screen scope dropdown's entire-display entries.
    static var displayTitles: [String] {
        screens.enumerated().map { row, screen in
            "\(row + 1): \(screen.localizedName)\(row == 0 ? " (main)" : "")"
        }
    }
}
