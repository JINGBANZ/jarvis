import AppKit

/// The menu-bar glyph has three states, and only one of them wants attention.
///
/// Stopped and the two exceptional live states (working, blocked) all draw the Listening Lens as
/// flat vector art onto a saturated colour plate. Stopped keeps the identity's own purple plate and
/// icy-blue crescent tint; working (amber) and blocked (red) drop that second hue for plain white so
/// the warning colour isn't fighting a brand hue. The application icon is a photographic render —
/// soft gradients, a glass highlight, a wireframe sphere — and none of that survives being
/// downsampled to 18 points, however much colour is poured into it, so all three draw the vector
/// artwork instead: it stays crisp at the only size this glyph is ever seen at.
///
/// Ready is the exception: a healthy session has nothing to announce, so it draws the same Listening
/// Lens as a bare template glyph instead — no plate, no colour — so it sits quietly among the rest of
/// the menu bar's monochrome status icons. `NSImage.isTemplate` hands tinting to AppKit, so it
/// follows the menu bar's light/dark appearance automatically.
///
/// All three render into a 2×-density bitmap at the same logical point size, so switching between
/// them never changes the glyph's footprint. Rendered once each and cached.
///
/// OS-bound (AppKit), so it lives in `JarvisApp` rather than Core and is verified by a live run, not
/// unit tests. Main-actor-isolated: `NSImage` isn't `Sendable`, and the icons are only ever touched
/// from the `@MainActor` `MenuBarController`. Signal's rendering colours live in
/// `MenuBarIcon+SignalRendering.swift`.
@MainActor
enum MenuBarIcon {
    /// What a live session looks like. Three readings, not four: `checking` and `recovering` share
    /// one, because both mean the same thing to someone glancing at the menu bar — working on it.
    enum Signal: Hashable {
        case ready
        case working
        case blocked
    }

    /// Logical (point) side of the square status image — comfortable in the ~22pt menu bar.
    private static let side: CGFloat = 18
    /// Render at 2× the logical size so the glyph is crisp on Retina displays.
    private static let scale: CGFloat = 2
    /// The drawn artwork is authored in a 36-unit square whose plate is inset by 2 on every side.
    /// Scaling it up by 36/32 lets the plate go full-bleed while the lens keeps its proportions.
    private static let artScale: CGFloat = 36.0 / 32.0

    /// The identity's own colours — the same purple plate and icy-blue crescent tint the app icon
    /// carries. Nothing about being stopped needs to compete for attention, so it stays on-brand
    /// rather than dimming, which is what working/blocked's saturated plates are reserved for.
    private static let stoppedPlate = NSColor(srgbRed: 123 / 255, green: 98 / 255, blue: 232 / 255, alpha: 1)
    private static let stoppedCoolTint = NSColor(srgbRed: 127 / 255, green: 196 / 255, blue: 242 / 255, alpha: 1)

    /// The Listening Lens on its purple plate, shown while stopped.
    static let stopped: NSImage = makeStopped()

    /// The lit Listening Lens for a live session. Cached per signal.
    static func live(_ signal: Signal) -> NSImage {
        if let cached = liveCache[signal] { return cached }
        let image = signal == .ready ? makeReadyTemplate() : makeLive(signal)
        liveCache[signal] = image
        return image
    }

    private static var liveCache: [Signal: NSImage] = [:]

    // MARK: - Stopped

    private static func makeStopped() -> NSImage {
        let rep = bitmap()
        paintPlateGlyph(in: rep, plate: stoppedPlate, coolTint: stoppedCoolTint)
        rep.size = NSSize(width: side, height: side)   // logical points → 2× pixel density
        return image(from: rep, describedAs: "Jarvis stopped")
    }

    // MARK: - Ready (template)

    /// Ready has nothing to announce, so it drops the colour plate entirely and draws just the
    /// Listening Lens glyph as a template image, the same convention the rest of the menu bar's
    /// monochrome status icons already follow. `isTemplate = true` hands the fill colour to AppKit,
    /// which matches it to the current menu bar appearance for free.
    private static func makeReadyTemplate() -> NSImage {
        let rep = bitmap()
        let px = CGFloat(rep.pixelsWide)
        let unit = px / 36

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        // Template images key off alpha, not colour, so any opaque fill works — black is convention.
        NSColor.black.setFill()
        coolCrescent(unit).fill()
        warmCrescent(unit).fill()
        core(unit).fill()

        NSGraphicsContext.restoreGraphicsState()

        rep.size = NSSize(width: side, height: side)
        return image(from: rep, describedAs: Signal.ready.accessibilityDescription, template: true)
    }

    // MARK: - Live

    private static func makeLive(_ signal: Signal) -> NSImage {
        let rep = bitmap()
        paintPlateGlyph(in: rep, plate: signal.plate, coolTint: signal.coolTint)
        rep.size = NSSize(width: side, height: side)
        return image(from: rep, describedAs: signal.accessibilityDescription)
    }

    /// The upper-left crescent, in the artwork's own coordinates.
    private static func coolCrescent(_ unit: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: point(26.4, 7.7, unit))
        path.curve(to: point(6.1, 13.2, unit),
                   controlPoint1: point(19.2, 3.2, unit), controlPoint2: point(10.1, 5.3, unit))
        path.curve(to: point(8.2, 27.3, unit),
                   controlPoint1: point(3.7, 17.9, unit), controlPoint2: point(4.5, 23.4, unit))
        path.curve(to: point(12.8, 12.8, unit),
                   controlPoint1: point(7.7, 22.2, unit), controlPoint2: point(9.1, 16.7, unit))
        path.curve(to: point(26.4, 7.7, unit),
                   controlPoint1: point(16.3, 9.1, unit), controlPoint2: point(21.3, 7.5, unit))
        path.close()
        return path
    }

    /// The lower-right crescent, always white — it is the one that has to read at 18 points.
    private static func warmCrescent(_ unit: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: point(9.6, 28.3, unit))
        path.curve(to: point(29.9, 22.8, unit),
                   controlPoint1: point(16.8, 32.8, unit), controlPoint2: point(25.9, 30.7, unit))
        path.curve(to: point(27.8, 8.7, unit),
                   controlPoint1: point(32.3, 18.1, unit), controlPoint2: point(31.5, 12.6, unit))
        path.curve(to: point(23.2, 23.2, unit),
                   controlPoint1: point(28.3, 13.8, unit), controlPoint2: point(26.9, 19.3, unit))
        path.curve(to: point(9.6, 28.3, unit),
                   controlPoint1: point(19.7, 26.9, unit), controlPoint2: point(14.7, 28.5, unit))
        path.close()
        return path
    }

    /// The glowing core the crescents wrap around.
    private static func core(_ unit: CGFloat) -> NSBezierPath {
        let radius: CGFloat = 4.2
        let topLeft = point(18 - radius, 18 + radius, unit)   // y flips, so this is the rect's origin
        let diameter = radius * 2 * artScale * unit
        return NSBezierPath(ovalIn: NSRect(x: topLeft.x, y: topLeft.y,
                                           width: diameter, height: diameter))
    }

    /// Map the artwork's design space — 36 units, y pointing down, plate inset by 2 — onto the
    /// bitmap's pixel space, where y points up and the plate is full-bleed. Done per point rather
    /// than with a composed `AffineTransform` so the order of operations is impossible to misread.
    private static func point(_ x: CGFloat, _ y: CGFloat, _ unit: CGFloat) -> CGPoint {
        CGPoint(x: (18 + (x - 18) * artScale) * unit,
                y: (18 - (y - 18) * artScale) * unit)
    }

    // MARK: - Shared

    /// Shared plate + Listening Lens paint routine for every state that draws a coloured plate
    /// (stopped, working, blocked) — only their two colours differ; the white crescent and core are
    /// constant.
    private static func paintPlateGlyph(in rep: NSBitmapImageRep, plate: NSColor, coolTint: NSColor) {
        let px = CGFloat(rep.pixelsWide)
        let unit = px / 36

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        plate.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: px, height: px),
                     xRadius: cornerRadius(for: rep), yRadius: cornerRadius(for: rep)).fill()

        coolTint.setFill()
        coolCrescent(unit).fill()

        NSColor.white.setFill()
        warmCrescent(unit).fill()
        core(unit).fill()

        NSGraphicsContext.restoreGraphicsState()
    }

    private static func bitmap() -> NSBitmapImageRep {
        let px = Int((side * scale).rounded())
        return NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                isPlanar: false, colorSpaceName: .deviceRGB,
                                bytesPerRow: 0, bitsPerPixel: 0)!
    }

    /// Every rendering shares the same corner radius, so the silhouette never changes.
    private static func cornerRadius(for rep: NSBitmapImageRep) -> CGFloat {
        CGFloat(rep.pixelsWide) * 0.225
    }

    private static func image(from rep: NSBitmapImageRep, describedAs description: String,
                              template: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        image.isTemplate = template               // false keeps our own colours; true hands tinting to AppKit
        image.accessibilityDescription = description
        return image
    }
}
