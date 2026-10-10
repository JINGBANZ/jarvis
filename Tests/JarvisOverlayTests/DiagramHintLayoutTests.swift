import Foundation
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct DiagramHintLayoutTests {
    @Test(arguments: [320.0, 520.0, 740.0])
    func crowdedConnectionsAvoidSharedRoutingLanes(_ width: Double) throws {
        let graph = try #require(DiagramHint(mermaid: """
        flowchart LR
        client[Client] -->|Request package| api[Package service]
        api -->|Check permission| access[Access service]
        api -->|Read package manifest| manifest[Manifest store]
        api -->|Return temporary links| client
        client -->|Fetch package bytes| edge[Edge cache]
        edge -->|Fetch missing objects| origin[Object store]
        client -->|Check current access| access
        """))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: width, height: 350),
            box: CGSize(width: 144, height: 52), edgeLabel: CGSize(width: 100, height: 36), margin: 16)
        #expect(layout.prefersConnectionRows)
    }

    @Test func horizontalReturnsAndBypassesUseOppositeSides() throws {
        let graph = try #require(DiagramHint(mermaid: """
        flowchart LR
        A[API] --> B[Worker]
        B --> C[Store]
        A -->|Bypass| C
        C -.->|Retry| A
        """))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: 1200, height: 300),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        #expect(layout.horizontal)
        let top = layout.frames.values.map(\.minY).min()!
        let bottom = layout.frames.values.map(\.maxY).max()!
        #expect(layout.routes[2].points.contains { $0.y > bottom })
        #expect(layout.routes[3].points.contains { $0.y < top })
        for route in layout.routes {
            #expect(route.points.allSatisfy { CGRect(origin: .zero, size: layout.size).contains($0) })
        }
    }

    @Test(arguments: [200.0, 520.0, 740.0])
    func returnsAndBypassesUseOppositeSides(_ width: Double) throws {
        let graph = try #require(DiagramHint(mermaid: """
        flowchart TD
        A[Intake] --> B[Extract]
        B --> C[Verify]
        C --> D[Record]
        D --> E[Audit]
        A -->|Bypass| D
        E -.->|Correction| B
        """))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: width, height: 300),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        let left = layout.frames.values.map(\.minX).min()!
        let right = layout.frames.values.map(\.maxX).max()!
        #expect(layout.routes[5].points.contains { $0.x < left })
        #expect(layout.routes[4].points.contains { $0.x > right })
        let extract = layout.frames["B"]!, record = layout.frames["D"]!
        #expect(layout.routes[5].points.last == CGPoint(x: extract.minX, y: extract.midY))
        #expect(layout.routes[4].points.last == CGPoint(x: record.maxX, y: record.midY))
        #expect(layout.size.width <= width)
        for route in layout.routes {
            #expect(route.points.allSatisfy { CGRect(origin: .zero, size: layout.size).contains($0) })
        }
        if width >= 520 {
            #expect(layout.routes[5].labelCenter.x + 50 < left)
            #expect(layout.routes[4].labelCenter.x - 50 > right)
        }
    }

    @Test(arguments: [320.0, 520.0, 740.0])
    func longFlowKeepsOneReadingDirection(_ width: Double) throws {
        let graph = try #require(DiagramHint(mermaid: "flowchart LR\n" + (0..<8).map {
            "N\($0)[Step \($0)] --> N\($0 + 1)[Step \($0 + 1)]"
        }.joined(separator: "\n")))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: width, height: 200),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        #expect(layout.size.width <= width)
        for edge in graph.edges {
            let from = try #require(layout.frames[edge.from])
            let to = try #require(layout.frames[edge.to])
            #expect(to.minY > from.maxY)
            #expect(to.midX == from.midX)
        }
    }

    @Test func requestedTopDownFlowDoesNotRotateToSaveHeight() throws {
        let graph = try #require(DiagramHint(mermaid:
            "flowchart TD\nA[Client] --> B[API]\nB --> C[Store]"))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: 900, height: 80),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        #expect(!layout.horizontal)
        #expect(layout.frames["C"]!.minY > layout.frames["B"]!.maxY)
        #expect(layout.size.height > 80)
    }

    @Test func aContinuingBranchKeepsItsColumn() throws {
        let graph = try #require(DiagramHint(mermaid: """
            flowchart TD
            A[Log] --> B[Live]
            A --> C[Archive]
            B --> D[Counts]
            C --> E[Files]
            E --> F[Enrichment]
            """))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: 520, height: 350),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        #expect(layout.frames["F"]!.midX == layout.frames["E"]!.midX)
        #expect(layout.routes.last!.points.count == 2)
    }

    @Test func horizontalReturnArrowsStayInsideTheImage() throws {
        let graph = try #require(DiagramHint(mermaid:
            "flowchart LR\nA[Input] --> B[Check]\nB --> C[Output]\nC -->|retry| A"))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: 900, height: 250),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        #expect(layout.horizontal)
        let bounds = CGRect(origin: .zero, size: layout.size)
        for route in layout.routes {
            #expect(route.points.allSatisfy { bounds.contains($0) })
        }
    }

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

    @Test func longWorkflowScrollsWithoutShrinkingBoxes() throws {
        let source = "flowchart LR\n" + (0..<8).map {
            "N\($0)[Step \($0)] --> N\($0 + 1)[Step \($0 + 1)]"
        }.joined(separator: "\n")
        let graph = try #require(DiagramHint(mermaid: source))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: 520, height: 350),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        #expect(layout.size.width <= 520)
        #expect(layout.size.height > 350)
        #expect(Set(layout.frames.values.map(\.minX)).count == 1)
        #expect(Set(layout.frames.values.map(\.minY)).count >= 2)
        #expect(layout.frames.count == 9)
        for (id, frame) in layout.frames {
            #expect(frame.size == CGSize(width: 144, height: 36))
            #expect(CGRect(origin: .zero, size: layout.size).contains(frame))
            #expect(layout.frames.allSatisfy { $0.key == id || !$0.value.intersects(frame) })
        }
    }

    @Test(arguments: ["LR", "TD"])
    func consecutiveNodesUseStraightArrows(_ direction: String) throws {
        let source = "flowchart \(direction)\n" + (0..<8).map {
            "N\($0)[Step \($0)] --> N\($0 + 1)[Step \($0 + 1)]"
        }.joined(separator: "\n")
        let graph = try #require(DiagramHint(mermaid: source))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: 520, height: 350),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        let routes = layout.routes
        for (edge, route) in zip(graph.edges, routes) {
            let from = try #require(layout.frames[edge.from])
            let to = try #require(layout.frames[edge.to])
            #expect(to.minY > from.maxY)
            #expect(from.midX == to.midX)
            #expect(route.points == [CGPoint(x: from.midX, y: from.maxY),
                                     CGPoint(x: to.midX, y: to.minY)])
        }
    }

    @Test(arguments: [380.0, 520.0, 740.0])
    func branchesAndReturnArrowsKeepEveryConnectionClear(_ width: Double) throws {
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
        let routes = layout.routes
        #expect(routes.count == graph.edges.count)
        #expect(layout.frames.count == graph.nodes.count)
        let bounds = CGRect(origin: .zero, size: layout.size)
        var labels: [CGRect] = []
        for (edge, route) in zip(graph.edges, routes) {
            let from = try #require(layout.frames[edge.from])
            let to = try #require(layout.frames[edge.to])
            #expect(route.points.first == CGPoint(x: from.midX, y: from.maxY))
            let end = try #require(route.points.last)
            #expect(end == CGPoint(x: to.midX, y: to.minY)
                || end == CGPoint(x: to.minX, y: to.midY)
                || end == CGPoint(x: to.maxX, y: to.midY))
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

    @Test func layoutDoesNotJoinIndependentWorkflows() throws {
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
        let routes = layout.routes
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

    @Test func returnArrowsDoNotJoinIndependentWorkflows() throws {
        let graph = try #require(DiagramHint(mermaid: """
            flowchart TD
            A[A] --> B[B]
            B --> A
            C[C] --> D[D]
            D --> C
            """))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: 520, height: 350),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        let routes = layout.routes
        for first in 0..<2 {
            for second in 2..<4 {
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
