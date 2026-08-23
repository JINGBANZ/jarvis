import AppKit
import CoreImage

/// The menu-bar glyph has two jobs, and they pull in opposite directions, so it is drawn two ways.
///
/// Stopped reuses the application icon with a high-contrast treatment tuned for its tiny display
/// size: no colour, deeper shadows, and a fine pale edge. That rendering is deliberately unchanged —
/// it is the resting state a person sees all day.
///
/// A live session gets the Listening Lens redrawn as flat vector art instead. The application icon
/// is a photographic render — soft gradients, a glass highlight, a wireframe sphere — and none of
/// that survives being downsampled to 18 points, however much colour is poured into it. Drawn
/// artwork stays crisp at the only size this glyph is ever seen at, and a saturated plate is the
/// loudest a status item can be without moving or growing.
///
/// Both paths render into a 2×-density bitmap at the same logical point size and share the same
/// rounded-square silhouette, so switching between them changes the icon's colour, never its shape
/// or footprint. Rendered once each and cached.
///
/// OS-bound (AppKit + CoreImage), so it lives in `JarvisApp` rather than Core and is verified by a
/// live run, not unit tests. Main-actor-isolated: `NSImage` isn't `Sendable`, and the icons are only
/// ever touched from the `@MainActor` `MenuBarController`.
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

    /// Quieter monochrome Listening Lens, shown while stopped.
    static let stopped: NSImage = makeStopped()

    /// The lit Listening Lens for a live session. Cached per signal.
    static func live(_ signal: Signal) -> NSImage {
        if let cached = liveCache[signal] { return cached }
        let image = makeLive(signal)
        liveCache[signal] = image
        return image
    }

    private static var liveCache: [Signal: NSImage] = [:]

    // MARK: - Stopped

    private static func makeStopped() -> NSImage {
        let base = renderBitmap()
        let rep = drainColour(base) ?? base
        addEdge(to: rep)
        rep.size = NSSize(width: side, height: side)   // logical points → 2× pixel density
        return image(from: rep, describedAs: "Jarvis stopped")
    }

    /// Draw the application icon into a 2×-density RGBA bitmap whose logical size is `side` points.
    private static func renderBitmap() -> NSBitmapImageRep {
        let rep = bitmap()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        guard let applicationIcon = NSApplication.shared.applicationIconImage else {
            preconditionFailure("Jarvis application icon is missing")
        }
        let px = CGFloat(rep.pixelsWide)
        applicationIcon.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                             from: .zero, operation: .sourceOver, fraction: 1,
                             respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Increase contrast only after downsampling so dark backing pixels recede while the glass arcs
    /// and core remain obvious at 18 points, and drop the colour entirely.
    private static func drainColour(_ rep: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard let cg = rep.cgImage,
              let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        filter.setValue(1.35, forKey: kCIInputContrastKey)
        filter.setValue(-0.05, forKey: kCIInputBrightnessKey)
        guard let output = filter.outputImage,
              let outCG = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSBitmapImageRep(cgImage: outCG)
    }

    /// A sub-point pale edge separates the dark rounded tile from a dark or translucent menu bar.
    /// It is drawn in Retina pixels before `rep.size` establishes the final logical point size.
    private static func addEdge(to rep: NSBitmapImageRep) {
        let lineWidth: CGFloat = 1.5
        let inset = lineWidth / 2
        let bounds = NSRect(x: inset, y: inset,
                            width: CGFloat(rep.pixelsWide) - lineWidth,
                            height: CGFloat(rep.pixelsHigh) - lineWidth)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedWhite: 1, alpha: 0.5).setStroke()
        let edge = NSBezierPath(roundedRect: bounds,
                                xRadius: cornerRadius(for: rep), yRadius: cornerRadius(for: rep))
        edge.lineWidth = lineWidth
        edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Live

    private static func makeLive(_ signal: Signal) -> NSImage {
        let rep = bitmap()
        let px = CGFloat(rep.pixelsWide)
        let unit = px / 36

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        signal.plate.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: px, height: px),
                     xRadius: cornerRadius(for: rep), yRadius: cornerRadius(for: rep)).fill()

        signal.coolTint.setFill()
        coolCrescent(unit).fill()

        NSColor.white.setFill()
        warmCrescent(unit).fill()
        core(unit).fill()

        NSGraphicsContext.restoreGraphicsState()

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

    private static func bitmap() -> NSBitmapImageRep {
        let px = Int((side * scale).rounded())
        return NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                isPlanar: false, colorSpaceName: .deviceRGB,
                                bytesPerRow: 0, bitsPerPixel: 0)!
    }

    /// Both renderings share the stopped tile's corner radius, so the silhouette never changes.
    private static func cornerRadius(for rep: NSBitmapImageRep) -> CGFloat {
        CGFloat(rep.pixelsWide) * 0.225
    }

    private static func image(from rep: NSBitmapImageRep, describedAs description: String) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        image.isTemplate = false                 // keep our own colours; don't tint to the label colour
        image.accessibilityDescription = description
        return image
    }
}

private extension MenuBarIcon.Signal {
    /// The plate carries the state. It is the largest area in the glyph, so it is the only element
    /// that reads reliably in peripheral vision.
    var plate: NSColor {
        switch self {
        case .ready:   NSColor(srgbRed: 123 / 255, green: 98 / 255, blue: 232 / 255, alpha: 1)
        case .working: NSColor(srgbRed: 224 / 255, green: 138 / 255, blue: 30 / 255, alpha: 1)
        case .blocked: NSColor(srgbRed: 216 / 255, green: 69 / 255, blue: 58 / 255, alpha: 1)
        }
    }

    /// Ready keeps the identity's second hue, the app icon's ice blue. The exceptional states drop
    /// it for a plain white tint: a second brand hue laid over amber or red fights the meaning the
    /// plate is carrying, and semantics win over decoration when something needs attention.
    var coolTint: NSColor {
        switch self {
        case .ready:             NSColor(srgbRed: 127 / 255, green: 196 / 255, blue: 242 / 255, alpha: 1)
        case .working, .blocked: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.62)
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .ready:   "Jarvis is listening"
        case .working: "Jarvis is starting"
        case .blocked: "Jarvis needs attention"
        }
    }
}
