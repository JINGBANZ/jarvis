import AppKit
import CoreImage

/// The menu-bar glyph: the robot emoji, in colour while running and desaturated to black-and-white
/// while stopped. Emoji are inherently colour glyphs, so the stopped variant is rendered to an image
/// and stripped of saturation. Both variants are rendered once and cached.
///
/// OS-bound (AppKit + CoreImage), so it lives in `JarvisApp` rather than Core and is verified by a
/// live run, not unit tests. Main-actor-isolated: `NSImage` isn't `Sendable`, and the icons are only
/// ever touched from the `@MainActor` `MenuBarController`.
@MainActor
enum MenuBarIcon {
    private static let emoji = "🤖"
    /// Point size that renders to roughly an 18pt-tall glyph — comfortable in the ~22pt menu bar.
    private static let pointSize: CGFloat = 15

    /// Full-colour robot, shown while the pipeline is running.
    static let running: NSImage = render(grayscale: false)
    /// Desaturated robot, shown while stopped.
    static let stopped: NSImage = render(grayscale: true)

    private static func render(grayscale: Bool) -> NSImage {
        let string = NSAttributedString(string: emoji,
                                        attributes: [.font: NSFont.systemFont(ofSize: pointSize)])
        let size = string.size()
        let base = NSImage(size: size)
        base.lockFocus()
        string.draw(at: .zero)
        base.unlockFocus()
        return grayscale ? (desaturate(base) ?? base) : base
    }

    /// Strip all colour (saturation → 0) so the stopped state reads as black-and-white.
    private static func desaturate(_ image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let input = CIImage(data: tiff),
              let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return result
    }
}
