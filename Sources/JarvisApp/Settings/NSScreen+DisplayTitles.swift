import AppKit

extension NSScreen {
    /// Numbered by `screencapture -D` index, main display first. The prefix also keeps titles
    /// unique, because `NSPopUpButton` silently drops duplicate titles such as two identical
    /// monitors.
    static var displayTitles: [String] {
        screens.enumerated().map { row, screen in
            "\(row + 1): \(screen.localizedName)\(row == 0 ? " (main)" : "")"
        }
    }
}
