import AppKit
import CoreImage

/// The menu-bar glyph: the robot emoji, in colour while running and desaturated to black-and-white
/// while stopped. Emoji are inherently colour glyphs, so the stopped variant is rendered and stripped
/// of saturation. Both variants share one rendering pipeline — drawn centred into the same 2×-density
/// bitmap at the same logical point size — so they match exactly and stay crisp on Retina displays.
/// Rendered once and cached.
///
/// OS-bound (AppKit + CoreImage), so it lives in `JarvisApp` rather than Core and is verified by a
/// live run, not unit tests. Main-actor-isolated: `NSImage` isn't `Sendable`, and the icons are only
/// ever touched from the `@MainActor` `MenuBarController`.
@MainActor
enum MenuBarIcon {
    private static let emoji = "🤖"
    /// Logical (point) side of the square status image — comfortable in the ~22pt menu bar.
    private static let side: CGFloat = 18
    /// Render at 2× the logical size so the glyph is crisp on Retina displays.
    private static let scale: CGFloat = 2

    /// Full-colour robot, shown while the pipeline is running.
    static let running: NSImage = make(grayscale: false)
    /// Desaturated robot, shown while stopped.
    static let stopped: NSImage = make(grayscale: true)

    private static func make(grayscale: Bool) -> NSImage {
        let base = renderBitmap()
        let rep = grayscale ? (desaturate(base) ?? base) : base
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        image.isTemplate = false                 // keep our own colours/greys; don't tint to the label colour
        image.accessibilityDescription = grayscale ? "Jarvis stopped" : "Jarvis running"
        return image
    }

    /// Draw the emoji centred into a 2×-density RGBA bitmap whose logical size is `side` points.
    private static func renderBitmap() -> NSBitmapImageRep {
        let px = Int((side * scale).rounded())
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let string = NSAttributedString(string: emoji,
                                        attributes: [.font: NSFont.systemFont(ofSize: side * scale)])
        let glyph = string.size()
        // Centre in the (pixel-space) canvas so the glyph isn't clipped or baseline-offset.
        string.draw(at: NSPoint(x: (CGFloat(px) - glyph.width) / 2,
                                y: (CGFloat(px) - glyph.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: side, height: side)   // logical points → 2× pixel density
        return rep
    }

    /// Strip all colour (saturation → 0) so the stopped state reads as black-and-white, keeping the
    /// same pixel dimensions and logical size as the colour variant.
    private static func desaturate(_ rep: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard let cg = rep.cgImage,
              let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
              let outCG = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let outRep = NSBitmapImageRep(cgImage: outCG)
        outRep.size = rep.size
        return outRep
    }
}
