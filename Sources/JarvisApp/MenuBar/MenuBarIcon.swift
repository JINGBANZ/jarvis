import AppKit

/// The menu-bar glyph has four readings. Stopped is a closed eye; active is the same eye open.
/// Both are bare template glyphs, so AppKit supplies the correct monochrome tint for the current
/// menu-bar appearance. That closed-to-open change carries the normal state transition without a
/// coloured plate competing with the rest of the menu bar.
///
/// Preflight and blocked are the exceptions because they need attention. They keep the open eye on
/// an amber or red plate. The application icon is a photographic render, but its gradients and glass
/// detail do not survive at 18 points, so every state uses crisp vector silhouettes instead.
///
/// All states render into a 2×-density bitmap at the same logical point size, so switching between
/// them never changes the glyph's footprint. Each image is rendered once and cached.
///
/// OS-bound (AppKit), so it lives in `JarvisApp` rather than Core and is verified by a live run, not
/// unit tests. Main-actor-isolated: `NSImage` isn't `Sendable`, and the icons are only ever touched
/// from the `@MainActor` `MenuBarController`.
@MainActor
enum MenuBarIcon {
    /// Checking and recovering share preflight because both mean Jarvis is establishing or
    /// restoring readiness, while active means it is listening.
    enum Signal: Hashable {
        case active
        case preflight
        case blocked
    }

    /// Logical (point) side of the square status image — comfortable in the ~22pt menu bar.
    private static let side: CGFloat = 18
    /// Render at 2× the logical size so the glyph is crisp on Retina displays.
    private static let scale: CGFloat = 2
    /// The open artwork is authored in a 36-unit square with a two-unit inset.
    private static let artScale: CGFloat = 36.0 / 32.0

    /// The closed, boxless eye shown while stopped.
    static let stopped: NSImage = makeStoppedTemplate()

    /// The icon for a session in progress. Cached per signal.
    static func live(_ signal: Signal) -> NSImage {
        if let cached = liveCache[signal] { return cached }
        let image = signal == .active ? makeActiveTemplate() : makeAttention(signal)
        liveCache[signal] = image
        return image
    }

    private static var liveCache: [Signal: NSImage] = [:]

    // MARK: - Stopped

    /// Two opposed eyelids rotated onto the open eye's 45-degree orbital axis.
    private static func makeStoppedTemplate() -> NSImage {
        let rep = bitmap()
        let unit = CGFloat(rep.pixelsWide) / 36
        paintTemplate(in: rep, paths: [closedCoolLid(unit), closedWarmLid(unit)])
        rep.size = NSSize(width: side, height: side)
        return image(from: rep, describedAs: "Jarvis is stopped", template: true)
    }

    // MARK: - Active

    /// An active session has nothing exceptional to announce, so the open eye stays monochrome.
    private static func makeActiveTemplate() -> NSImage {
        let rep = bitmap()
        let unit = CGFloat(rep.pixelsWide) / 36
        paintTemplate(in: rep, paths: [coolCrescent(unit), warmCrescent(unit), core(unit)])
        rep.size = NSSize(width: side, height: side)
        return image(from: rep, describedAs: Signal.active.accessibilityDescription, template: true)
    }

    // MARK: - Attention states

    private static func makeAttention(_ signal: Signal) -> NSImage {
        let rep = bitmap()
        paintPlateGlyph(in: rep, plate: signal.plate, coolTint: signal.coolTint)
        rep.size = NSSize(width: side, height: side)
        return image(from: rep, describedAs: signal.accessibilityDescription)
    }

    /// Upper and lower lids are authored horizontally, then rotated together so the stopped eye
    /// keeps the same diagonal axis as the open orbital mark. The negative seam is the state cue.
    private static func closedCoolLid(_ unit: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: closedPoint(4.5, 17.4, unit))
        path.curve(
            to: closedPoint(31.5, 17.4, unit),
            controlPoint1: closedPoint(10, 6.5, unit),
            controlPoint2: closedPoint(26, 6.5, unit))
        path.curve(
            to: closedPoint(4.5, 17.4, unit),
            controlPoint1: closedPoint(25, 16.6, unit),
            controlPoint2: closedPoint(11, 16.6, unit))
        path.close()
        return path
    }

    private static func closedWarmLid(_ unit: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: closedPoint(4.5, 18.6, unit))
        path.curve(
            to: closedPoint(31.5, 18.6, unit),
            controlPoint1: closedPoint(11, 19.4, unit),
            controlPoint2: closedPoint(25, 19.4, unit))
        path.curve(
            to: closedPoint(4.5, 18.6, unit),
            controlPoint1: closedPoint(26, 29.5, unit),
            controlPoint2: closedPoint(10, 29.5, unit))
        path.close()
        return path
    }

    /// Rotate in the artwork's y-down coordinate space before mapping into AppKit's y-up bitmap.
    private static func closedPoint(_ x: CGFloat, _ y: CGFloat, _ unit: CGFloat) -> CGPoint {
        let angle = -CGFloat.pi / 4
        let dx = x - 18
        let dy = y - 18
        let rotatedX = 18 + dx * cos(angle) - dy * sin(angle)
        let rotatedY = 18 + dx * sin(angle) + dy * cos(angle)
        return point(rotatedX, rotatedY, unit)
    }

    /// The upper-left crescent in the open eye.
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

    /// The lower-right crescent in the open eye.
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

    /// The core visible only while the eye is open.
    private static func core(_ unit: CGFloat) -> NSBezierPath {
        let radius: CGFloat = 4.2
        let topLeft = point(18 - radius, 18 + radius, unit)
        let diameter = radius * 2 * artScale * unit
        return NSBezierPath(ovalIn: NSRect(x: topLeft.x, y: topLeft.y,
                                           width: diameter, height: diameter))
    }

    /// Map the artwork's 36-unit, y-down design space onto the bitmap's y-up pixel space.
    private static func point(_ x: CGFloat, _ y: CGFloat, _ unit: CGFloat) -> CGPoint {
        CGPoint(x: (18 + (x - 18) * artScale) * unit,
                y: (18 - (y - 18) * artScale) * unit)
    }

    // MARK: - Shared

    private static func paintTemplate(in rep: NSBitmapImageRep, paths: [NSBezierPath]) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Template images use alpha as their mask, so the source fill colour is irrelevant.
        NSColor.black.setFill()
        paths.forEach { $0.fill() }
        NSGraphicsContext.restoreGraphicsState()
    }

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

    private static func cornerRadius(for rep: NSBitmapImageRep) -> CGFloat {
        CGFloat(rep.pixelsWide) * 0.225
    }

    private static func image(from rep: NSBitmapImageRep, describedAs description: String,
                              template: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        image.isTemplate = template
        image.accessibilityDescription = description
        return image
    }
}

private extension MenuBarIcon.Signal {
    var plate: NSColor {
        switch self {
        case .active:
            preconditionFailure("active renders as a template glyph")
        case .preflight:
            NSColor(srgbRed: 224 / 255, green: 138 / 255, blue: 30 / 255, alpha: 1)
        case .blocked:
            NSColor(srgbRed: 216 / 255, green: 69 / 255, blue: 58 / 255, alpha: 1)
        }
    }

    var coolTint: NSColor {
        switch self {
        case .active:
            preconditionFailure("active renders as a template glyph")
        case .preflight, .blocked:
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.62)
        }
    }

    /// The status item's accessibility label carries exact readiness detail. This description names
    /// only the cached image shared by checking and recovering.
    var accessibilityDescription: String {
        switch self {
        case .active: "Jarvis is active"
        case .preflight: "Jarvis is checking readiness"
        case .blocked: "Jarvis needs attention"
        }
    }
}
