import Foundation
import Testing
@testable import JarvisCore

@Suite struct DiagramHintTests {
    @Test func acceptsMermaidColoredAndDashedEdges() throws {
        let graph = try #require(DiagramHint(mermaid: """
        flowchart TD
        A[API] -->|Publish| K[Kafka]
        K -->|Consume batch| W[Worker]
        W -.->|Retry failed events| K
        linkStyle 0,1 stroke:#EAB308,stroke-width:3px
        linkStyle 2 stroke:#C084FC,stroke-width:2px
        """))
        #expect(graph.edges.map(\.label) == ["Publish", "Consume batch", "Retry failed events"])
        #expect(graph.edges.map(\.dashed) == [false, false, true])
        #expect(graph.edges.map(\.stroke) == [0xEAB308, 0xEAB308, 0xC084FC])
        #expect(graph.edges.map(\.strokeWidth) == [3, 3, 2])
    }

    @Test(arguments: [
        "linkStyle 1 stroke:#EAB308", "linkStyle 0 stroke:url(https://example.com)",
        "linkStyle 0 stroke:#EAB308,opacity:0", "linkStyle 0 stroke:#EAB308,stroke-width:90px",
        "linkStyle -1 stroke:#EAB308", "linkStyle 0 stroke:#EAB308;click A evil",
    ])
    func rejectsUnsafeOrInvalidEdgeStyles(_ style: String) {
        #expect(DiagramHint(mermaid: "flowchart TD\nA[API] --> B[DB]\n" + style) == nil)
    }

    @Test func parsesBoxesAndLabeledConnections() throws {
        let graph = try #require(DiagramHint(mermaid: """
        flowchart LR
        client["Client"] -->|HTTPS| api["API service"]
        api --> db["Database"]
        api --> cache["Cache"]
        """))
        #expect(graph.nodes.map(\.label) == ["Client", "API service", "Database", "Cache"])
        #expect(graph.edges.map(\.label) == ["HTTPS", nil, nil])
        #expect(graph.edges[1].from == "api")
        #expect(graph.edges[1].to == "db")
        #expect(graph.direction == .leftToRight)
    }

    @Test func acceptsSeparateDeclarationsAndCycles() throws {
        let graph = try #require(DiagramHint(mermaid: "graph TD\nA[API]\nB[Queue]\nA --> B\nB --> A"))
        #expect(graph.nodes.count == 2)
        #expect(graph.edges.count == 2)
        #expect(graph.direction == .topDown)
    }

    @Test(arguments: [
        "", "sequenceDiagram\nA->>B: hi", "flowchart LR\nA --> B",
        "flowchart LR\nA[API]\nclick A \"https://example.com\"",
        "flowchart LR\nA[<script>alert(1)</script>]",
        "flowchart LR\nA[API]\nA[Different]",
        "flowchart LR\nA[API]\nB[DB]\nA --> C",
        "flowchart LR\nA[API]\n%%{init: {}}%%",
        "flowchart LR\nA[API]\nA --> A",
    ])
    func rejectsUnsupportedOrAmbiguousGraphs(_ source: String) {
        #expect(DiagramHint(mermaid: source) == nil)
    }

    @Test func boundsGraphSize() {
        let oversized = "flowchart LR\n" + (0..<30).map { "N\($0)[Node]" }.joined(separator: "\n")
        #expect(DiagramHint(mermaid: oversized) == nil)
        #expect(DiagramHint(mermaid: "flowchart LR\nA[" + String(repeating: "x", count: 9000) + "]") == nil)
    }

    @Test func aDiagramTravelsInDetailAndAnUndeclaredFieldIsIgnored() {
        let call = ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON:
            #"{"lines":["Sketch the request path."],"detail":"```mermaid\nflowchart LR\nA[API]\n```"}"#)
        #expect(call == .speak(callId: "s", lines: ["Sketch the request path."],
                               detail: "```mermaid\nflowchart LR\nA[API]\n```"))
        #expect(ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON:
            #"{"lines":["Keep this hint."],"mermaid":"flowchart LR\nA[API]"}"#)
            == .speak(callId: "s", lines: ["Keep this hint."]))
    }
}
