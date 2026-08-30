import AppKit
import JarvisCore

extension NSEvent.ModifierFlags {
    /// Maps the four modifier keys the hotkey recorder cares about. NSEvent's flag bits don't match
    /// Carbon's masks, so this is an explicit translation rather than a `rawValue` reinterpretation.
    var hotkeyModifiers: HotkeyModifiers {
        var result: HotkeyModifiers = []
        if contains(.control) { result.insert(.control) }
        if contains(.option) { result.insert(.option) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.command) { result.insert(.command) }
        return result
    }
}
