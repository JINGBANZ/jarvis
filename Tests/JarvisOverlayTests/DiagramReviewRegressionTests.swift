import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct DiagramReviewRegressionTests {
    @Test(arguments: ["TD", "LR"])
    func reversedDeclarationsDoNotMergeIndependentConnections(_ direction: String) throws {
        let graph = try #require(DiagramHint(mermaid: """
        flowchart \(direction)
        A[First input]
        B[Second input]
        C[Second output]
        D[First output]
        A --> D
        B --> C
        """))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: 800, height: 350),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        #expect(layout.frames.count == 4)
        #expect(layout.routes.count == 2)
        for (a, b) in zip(layout.routes[0].points, layout.routes[0].points.dropFirst()) {
            for (c, d) in zip(layout.routes[1].points, layout.routes[1].points.dropFirst()) {
                let vertical = a.x == b.x && c.x == d.x && a.x == c.x
                    && max(min(a.y, b.y), min(c.y, d.y)) < min(max(a.y, b.y), max(c.y, d.y))
                let horizontal = a.y == b.y && c.y == d.y && a.y == c.y
                    && max(min(a.x, b.x), min(c.x, d.x)) < min(max(a.x, b.x), max(c.x, d.x))
                #expect(!vertical && !horizontal)
            }
        }
    }

    @MainActor @Test(arguments: ["000000", "000080", "EAB308", "C084FC", "FFFFFF"])
    func edgeLabelsHaveContrastingBackgrounds(_ hex: String) throws {
        let graph = try #require(DiagramHint(mermaid: """
        flowchart TD
        A[Input] -->|AA AA| B[Output]
        linkStyle 0 stroke:#\(hex)
        """))
        let available = CGSize(width: 200, height: 1)
        let drawing = DiagramHintImage.fittedDrawing(graph, fitting: available)
        let image = DiagramHintImage.render(graph, fitting: available)
        let bitmap = try #require(NSBitmapImageRep(data: try imageData(image)))
        let scale = CGFloat(bitmap.pixelsWide) / image.size.width
        let center = drawing.layout.routes[0].labelCenter
        let color = try #require(bitmap.colorAt(x: Int(center.x * scale), y: Int(center.y * scale))?.usingColorSpace(.deviceRGB))
        if hex == "000000" || hex == "000080" {
            #expect(color.redComponent > 0.8, "dark text needs a light background")
        } else {
            #expect(color.redComponent < 0.2, "light text keeps the dark background")
        }
    }

    @MainActor private func imageData(_ image: NSImage) throws -> Data {
        try #require(image.tiffRepresentation)
    }
}
