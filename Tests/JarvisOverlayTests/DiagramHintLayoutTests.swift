import Foundation
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct DiagramHintLayoutTests {
    @Test(arguments: [200.0, 320.0, 600.0])
    func wideBranchesWrapWithoutOverlappingOrOverflowing(_ width: Double) throws {
        let source = "flowchart TD\n" + (0..<7).map {
            "A[API] --> N\($0)[Worker \($0)]"
        }.joined(separator: "\n")
        let graph = try #require(DiagramHint(mermaid: source))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: width, height: 300),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        #expect(layout.size.width <= width)
        #expect(layout.frames.count == 8)
        let bounds = CGRect(origin: .zero, size: layout.size)
        for (id, frame) in layout.frames {
            #expect(bounds.contains(frame))
            #expect(frame.size == CGSize(width: 144, height: 36), "wrapping never shrinks node labels")
            #expect(layout.frames.allSatisfy { $0.key == id || !$0.value.intersects(frame) })
        }
    }

    @Test func outgoingLabelsHaveSeparateSpaceBeforeTheNextRow() throws {
        let graph = try #require(DiagramHint(mermaid:
            "flowchart TD\nA[API] -->|read| B[Cache]\nA -->|write| C[Database]"))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: 200, height: 100),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        let api = try #require(layout.frames["A"])
        let cache = try #require(layout.frames["B"])
        let database = try #require(layout.frames["C"])
        #expect(cache.minY - api.maxY >= 2 * 20 + 16)
        #expect(database.minY > cache.maxY)
        #expect(layout.size.width <= 200)
    }

    @Test func aNarrowPanelReflowsTheRequestedHorizontalChain() throws {
        let graph = try #require(DiagramHint(mermaid:
            "flowchart LR\nA[Client] --> B[API]\nB --> C[Store]"))
        func layout(_ width: CGFloat) -> DiagramHintLayout {
            DiagramHintLayout(graph, fitting: CGSize(width: width, height: 300),
                box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        }
        #expect(!layout(300).horizontal)
        #expect(layout(600).horizontal)
        #expect(layout(300).size.width <= 300)
        #expect(layout(600).size.width <= 600)
    }
}
