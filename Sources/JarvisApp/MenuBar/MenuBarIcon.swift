import AppKit
import CoreImage

/// The menu-bar glyph reuses the application icon with a high-contrast treatment tuned for its tiny
/// display size: deeper shadows, brighter highlights, and a fine pale edge. It stays in colour while
/// running and becomes a quieter monochrome while stopped. Both variants share one rendering
/// pipeline — drawn into the same 2×-density bitmap at the same logical point size — so they match
/// exactly and stay crisp on Retina displays. Rendered once and cached.
///
/// OS-bound (AppKit + CoreImage), so it lives in `JarvisApp` rather than Core and is verified by a
/// live run, not unit tests. Main-actor-isolated: `NSImage` isn't `Sendable`, and the icons are only
/// ever touched from the `@MainActor` `MenuBarController`.
@MainActor
enum MenuBarIcon {
    private enum State: Equatable {
        case running
        case stopped
    }

    /// Logical (point) side of the square status image — comfortable in the ~22pt menu bar.
    private static let side: CGFloat = 18
    /// Render at 2× the logical size so the glyph is crisp on Retina displays.
    private static let scale: CGFloat = 2

    /// Full-colour, high-contrast Listening Lens, shown while the pipeline is running.
    static let running: NSImage = make(state: .running)
    /// Quieter monochrome Listening Lens, shown while stopped.
    static let stopped: NSImage = make(state: .stopped)

    private static func make(state: State) -> NSImage {
        let base = renderBitmap()
        let rep = adjustContrast(base, for: state) ?? base
        addEdge(to: rep, for: state)
        rep.size = NSSize(width: side, height: side)   // logical points → 2× pixel density

        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        image.isTemplate = false                 // keep our own colours/greys; don't tint to the label colour
        image.accessibilityDescription = state == .stopped ? "Jarvis stopped" : "Jarvis running"
        return image
    }

    /// Draw the application icon into a 2×-density RGBA bitmap whose logical size is `side` points.
    private static func renderBitmap() -> NSBitmapImageRep {
        let px = Int((side * scale).rounded())
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        guard let applicationIcon = NSApplication.shared.applicationIconImage else {
            preconditionFailure("Jarvis application icon is missing")
        }
        applicationIcon.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                             from: .zero, operation: .sourceOver, fraction: 1,
                             respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Increase contrast only after downsampling so dark backing pixels recede while the glass arcs
    /// and core remain obvious at 18 points. The stopped state uses the same geometry with no colour
    /// and lower brightness, preserving the existing state distinction without a second asset.
    private static func adjustContrast(_ rep: NSBitmapImageRep, for state: State) -> NSBitmapImageRep? {
        guard let cg = rep.cgImage,
              let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        filter.setValue(state == .running ? 1.55 : 0.0, forKey: kCIInputSaturationKey)
        filter.setValue(1.35, forKey: kCIInputContrastKey)
        filter.setValue(state == .running ? 0.04 : -0.05, forKey: kCIInputBrightnessKey)
        guard let output = filter.outputImage,
              let outCG = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSBitmapImageRep(cgImage: outCG)
    }

    /// A sub-point pale edge separates the dark rounded tile from a dark or translucent menu bar.
    /// It is drawn in Retina pixels before `rep.size` establishes the final logical point size.
    private static func addEdge(to rep: NSBitmapImageRep, for state: State) {
        let lineWidth: CGFloat = 1.5
        let inset = lineWidth / 2
        let bounds = NSRect(x: inset, y: inset,
                            width: CGFloat(rep.pixelsWide) - lineWidth,
                            height: CGFloat(rep.pixelsHigh) - lineWidth)
        let cornerRadius = CGFloat(rep.pixelsWide) * 0.225

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedWhite: 1, alpha: state == .running ? 0.86 : 0.5).setStroke()
        let edge = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        edge.lineWidth = lineWidth
        edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
