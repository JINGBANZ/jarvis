#if JARVIS_LIVE_E2E
import AppKit

extension FixtureScreenCapture {
    @MainActor
    static func textJPEG(_ text: String) throws -> Data {
        let image = NSImage(size: NSSize(width: 1440, height: 960), flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            (text as NSString).draw(in: rect.insetBy(dx: 36, dy: 36), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 23, weight: .regular),
                .foregroundColor: NSColor.black,
            ])
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { throw CocoaError(.fileReadCorruptFile) }
        return jpeg
    }
}
#endif
