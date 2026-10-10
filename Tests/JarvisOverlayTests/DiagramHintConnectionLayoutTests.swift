import Foundation
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct DiagramHintConnectionLayoutTests {
    @Test(arguments: [200.0, 320.0, 520.0, 740.0])
    func preservesConnectionsAndIsolatedNodesWithoutOverlap(_ width: Double) throws {
        let graph = try #require(DiagramHint(mermaid: """
        flowchart TD
        A[Client] -->|Read| B[Service]
        B -->|Lookup| C[Store]
        B -.->|Respond| A
        D[Offline component]
        """))
        let layout = DiagramHintConnectionLayout(graph, width: width, nodeHeight: 68,
            labelHeight: 32, headerHeight: 48)
        #expect(layout.rows.map(\.source) == ["A", "B", "B", "D"])
        #expect(layout.rows.map(\.target) == ["B", "C", "A", nil])
        #expect(layout.rows.compactMap(\.edgeIndex) == [0, 1, 2])
        #expect(layout.size.width <= width)
        let bounds = CGRect(origin: .zero, size: layout.size)
        for (index, row) in layout.rows.enumerated() {
            #expect(bounds.contains(row.sourceFrame))
            #expect(bounds.contains(row.targetFrame))
            #expect(bounds.contains(row.labelFrame))
            #expect(row.labelFrame.maxY < row.sourceFrame.minY)
            #expect(row.sourceFrame.maxX < row.targetFrame.minX)
            if index > 0 {
                #expect(layout.rows[index - 1].sourceFrame.maxY < row.labelFrame.minY)
            }
        }
    }

    @Test func aSimpleBranchKeepsTheConnectedView() throws {
        let graph = try #require(DiagramHint(mermaid:
            "flowchart TD\nA[API] --> B[Cache]\nA --> C[Store]"))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: 520, height: 350),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        #expect(!layout.prefersConnectionRows)
    }
}
