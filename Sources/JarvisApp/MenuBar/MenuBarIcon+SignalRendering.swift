import AppKit

extension MenuBarIcon.Signal {
    /// The plate carries the state. It is the largest area in the glyph, so it is the only element
    /// that reads reliably in peripheral vision. Ready has no plate — it renders as a template glyph
    /// via `MenuBarIcon.makeReadyTemplate()` — so this is only ever read for the two states that need
    /// attention.
    var plate: NSColor {
        switch self {
        case .ready:   preconditionFailure("ready renders as a template glyph — see makeReadyTemplate()")
        case .working: NSColor(srgbRed: 224 / 255, green: 138 / 255, blue: 30 / 255, alpha: 1)
        case .blocked: NSColor(srgbRed: 216 / 255, green: 69 / 255, blue: 58 / 255, alpha: 1)
        }
    }

    /// Working and blocked drop the identity's ice-blue second hue for a plain white tint: a brand
    /// hue laid over amber or red fights the meaning the plate is carrying, and semantics win over
    /// decoration when something needs attention. Ready has no plate to tint — see `plate` above.
    var coolTint: NSColor {
        switch self {
        case .ready:              preconditionFailure("ready renders as a template glyph — see makeReadyTemplate()")
        case .working, .blocked:  NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.62)
        }
    }

    /// Describes the picture, not the session — `MenuBarController` labels the button itself with
    /// the exact status, and one image is shared by checking and recovering.
    var accessibilityDescription: String {
        switch self {
        case .ready:   "Jarvis is listening"
        case .working: "Jarvis is connecting"
        case .blocked: "Jarvis needs attention"
        }
    }
}
