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

    @Test func longWorkflowUsesSeveralColumnsWithoutShrinkingBoxes() throws {
        let source = "flowchart LR\n" + (0..<8).map {
            "N\($0)[Step \($0)] --> N\($0 + 1)[Step \($0 + 1)]"
        }.joined(separator: "\n")
        let graph = try #require(DiagramHint(mermaid: source))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: 520, height: 350),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        #expect(layout.size.width <= 520)
        #expect(layout.size.height <= 350)
        #expect(Set(layout.frames.values.map(\.minX)).count >= 2)
        #expect(Set(layout.frames.values.map(\.minY)).count >= 2)
        #expect(layout.frames.count == 9)
        for (id, frame) in layout.frames {
            #expect(frame.size == CGSize(width: 144, height: 36))
            #expect(CGRect(origin: .zero, size: layout.size).contains(frame))
            #expect(layout.frames.allSatisfy { $0.key == id || !$0.value.intersects(frame) })
        }
    }

    @Test(arguments: ["LR", "TD"])
    func consecutiveFoldedBandsTurnAlongTheirSharedSide(_ direction: String) throws {
        let source = "flowchart \(direction)\n" + (0..<8).map {
            "N\($0)[Step \($0)] --> N\($0 + 1)[Step \($0 + 1)]"
        }.joined(separator: "\n")
        let graph = try #require(DiagramHint(mermaid: source))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: 520, height: 350),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        let routes = try #require(layout.foldedRoutes)
        for (edge, route) in zip(graph.edges, routes) {
            let from = try #require(layout.frames[edge.from])
            let to = try #require(layout.frames[edge.to])
            guard from.minY != to.minY else { continue }
            #expect(from.minX == to.minX, "consecutive bands meet in the same column")
            let xs = route.points.map(\.x)
            #expect(xs.max()! - xs.min()! <= 144,
                    "a row turn stays local instead of doubling across the entire diagram")
        }
    }

    @Test(arguments: [380.0, 520.0, 740.0])
    func foldedBranchesAndReturnArrowsKeepEveryConnectionClear(_ width: Double) throws {
        let graph = try #require(DiagramHint(mermaid: """
            flowchart LR
            A[Intake] --> B[Extract]
            B --> C[Rules]
            C -->|routine| D[Draft]
            C -->|exception| E[Specialist]
            D --> F[Verify]
            E --> F
            F --> G[Record]
            G --> H[Audit]
            H -->|correct| B
            A --> G
            """))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: width, height: 350),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        let routes = try #require(layout.foldedRoutes)
        #expect(routes.count == graph.edges.count)
        #expect(layout.frames.count == graph.nodes.count)
        let bounds = CGRect(origin: .zero, size: layout.size)
        var labels: [CGRect] = []
        for (edge, route) in zip(graph.edges, routes) {
            let from = try #require(layout.frames[edge.from])
            let to = try #require(layout.frames[edge.to])
            #expect(route.points.first == CGPoint(x: from.midX, y: from.maxY))
            let end = try #require(route.points.last)
            #expect(end.y == to.midY && (end.x == to.minX || end.x == to.maxX))
            #expect(route.points.allSatisfy { bounds.contains($0) })
            for (a, b) in zip(route.points, route.points.dropFirst()) {
                #expect(a.x == b.x || a.y == b.y)
                let segment = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                    width: max(0.1, abs(a.x - b.x)), height: max(0.1, abs(a.y - b.y)))
                for frame in layout.frames.values {
                    #expect(!segment.intersects(frame.insetBy(dx: 1, dy: 1)))
                }
            }
            if edge.label != nil {
                let label = CGRect(x: route.labelCenter.x - 50, y: route.labelCenter.y - 10,
                                   width: 100, height: 20)
                #expect(bounds.contains(label))
                #expect(layout.frames.values.allSatisfy { !$0.intersects(label) })
                #expect(labels.allSatisfy { !$0.intersects(label) })
                labels.append(label)
            }
        }
    }

    @Test func foldingDoesNotJoinIndependentWorkflows() throws {
        let graph = try #require(DiagramHint(mermaid: """
            flowchart LR
            A[Start one] --> B[Prepare one]
            B --> C[Review one]
            C --> D[Confirm one]
            D --> I[Save one]
            I --> J[Finish one]
            E[Start two] --> F[Prepare two]
            F --> G[Review two]
            G --> H[Confirm two]
            H --> K[Save two]
            K --> L[Finish two]
            """))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: 520, height: 350),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        let routes = try #require(layout.foldedRoutes)
        for first in 0..<5 {
            for second in 5..<10 {
                for (a, b) in zip(routes[first].points, routes[first].points.dropFirst()) {
                    for (c, d) in zip(routes[second].points, routes[second].points.dropFirst()) {
                        let sharedVertical = a.x == b.x && c.x == d.x && a.x == c.x
                            && max(min(a.y, b.y), min(c.y, d.y)) < min(max(a.y, b.y), max(c.y, d.y))
                        let sharedHorizontal = a.y == b.y && c.y == d.y && a.y == c.y
                            && max(min(a.x, b.x), min(c.x, d.x)) < min(max(a.x, b.x), max(c.x, d.x))
                        #expect(!sharedVertical && !sharedHorizontal)
                    }
                }
            }
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
