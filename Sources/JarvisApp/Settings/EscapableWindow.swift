import AppKit

/// A plain `NSWindow` ignores `cancelOperation(_:)`, so Escape and Cmd-. wouldn't close it.
final class EscapableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
