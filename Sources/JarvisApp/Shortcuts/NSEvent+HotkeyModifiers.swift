import AppKit
import JarvisCore

extension NSEvent.ModifierFlags {
    /// NSEvent flag bits differ from Carbon masks, so translate rather than reuse `rawValue`.
    var hotkeyModifiers: HotkeyModifiers {
        var result: HotkeyModifiers = []
        if contains(.control) { result.insert(.control) }
        if contains(.option) { result.insert(.option) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.command) { result.insert(.command) }
        return result
    }
}
