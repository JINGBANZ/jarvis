import AppKit

/// A window that also closes on Escape (and Cmd-.), matching standard macOS settings-window
/// behavior. A plain `NSWindow` ignores `cancelOperation(_:)`. Shared by the Settings window and the
/// first-launch permission window so both dismiss the same way.
final class EscapableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
