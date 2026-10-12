import Foundation
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct DiagramHintBranchTests {
    @Test(arguments: [320.0, 520.0])
    func focusedBranchesStayConnectedAcrossThreeColumns(_ width: Double) throws {
        let graph = try #require(DiagramHint(mermaid: """
        flowchart TD
        A[Client] -->|Request links| B[Package service]
        A -->|Fetch files| C[Edge cache]
        B -->|Check rights| D[Rights service]
        B -->|Read manifest| E[Metadata]
        C -->|Cache miss| F[File store]
        """))
        let labelSize = CGSize(width: 80, height: 36)
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: width, height: 350),
            box: CGSize(width: 144, height: 54), edgeLabel: labelSize, margin: 16)
        #expect(layout.frames.count == 6)
        #expect(layout.routes.count == 5)
        #expect(layout.frames["B"]!.minY == layout.frames["C"]!.minY)
        #expect(layout.frames["D"]!.minY == layout.frames["E"]!.minY)
        #expect(layout.frames["E"]!.minY == layout.frames["F"]!.minY)
        #expect(layout.size.width <= width)
        var labels: [CGRect] = []
        for (edge, route) in zip(graph.edges, layout.routes) {
            let from = layout.frames[edge.from]!, to = layout.frames[edge.to]!
            #expect(route.points.count <= 4, "a focused tree needs no exterior detours")
            #expect(route.points.first == CGPoint(x: from.midX, y: from.maxY))
            #expect(route.points.last == CGPoint(x: to.midX, y: to.minY))
            let label = CGRect(x: route.labelCenter.x - 40, y: route.labelCenter.y - 18,
                               width: 80, height: 36)
            #expect(layout.frames.values.allSatisfy { !$0.intersects(label) })
            #expect(labels.allSatisfy { !$0.intersects(label) })
            labels.append(label)
        }
        #expect(layout.routes[0].labelCenter.x == layout.frames["B"]!.midX)
        #expect(layout.routes[1].labelCenter.x == layout.frames["C"]!.midX)
    }
}
