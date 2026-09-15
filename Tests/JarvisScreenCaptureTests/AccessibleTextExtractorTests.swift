import Testing
@testable import JarvisScreenCapture

@Suite struct AccessibleTextExtractorTests {
    @Test func preservesDocumentOrderAndSkipsSecureSubtrees() {
        let root = AccessibilityNode(role: "AXWebArea", children: [
            .init(role: "AXHeading", children: [
                .init(role: "AXStaticText", text: "Two Sum"),
            ]),
            .init(role: "AXSecureTextField", text: "hunter2", children: [
                .init(role: "AXStaticText", text: "also secret"),
            ]),
            .init(role: "AXTextField", text: "subrole secret", isSecure: true),
            .init(role: "AXStaticText", text: "Return the two indices."),
        ])

        let result = AccessibleTextExtractor().extract(root)

        #expect(result.text == "Two Sum\nReturn the two indices.")
        #expect(!result.truncated)
    }

    @Test func preservesRepeatedLines() {
        let root = AccessibilityNode(role: "AXWebArea", children: [
            .init(role: "AXStaticText", text: "Constraints"),
            .init(role: "AXStaticText", text: "Constraints"),
            .init(role: "AXStaticText", text: "0 <= n"),
            .init(role: "AXStaticText", text: "Constraints"),
        ])

        let result = AccessibleTextExtractor().extract(root)

        #expect(result.text == "Constraints\nConstraints\n0 <= n\nConstraints")
    }

    @Test func joinsInlineTextWithinSemanticBlock() {
        let root = AccessibilityNode(role: "AXWebArea", children: [
            .init(role: "AXHeading", children: [
                .init(role: "AXStaticText", text: "Calculate"),
                .init(role: "AXStaticText", text: "Total"),
            ]),
            .init(role: "AXParagraph", children: [
                .init(role: "AXStaticText", text: "Return"),
                .init(role: "AXStaticText", text: "quantity × price."),
            ]),
        ])

        let result = AccessibleTextExtractor().extract(root)

        #expect(result.text == "Calculate Total\nReturn quantity × price.")
    }

    @Test func editorTextPrecedesPageChromeWithinByteLimit() {
        let root = AccessibilityNode(role: "AXWebArea", children: [
            .init(role: "AXNavigation", children: [
                .init(role: "AXStaticText", text: "A very long navigation label"),
            ]),
            .init(role: "AXTextArea", text: "guard quantity >= 0"),
        ])

        let result = AccessibleTextExtractor(byteLimit: 19).extract(root)

        #expect(result.text == "guard quantity >= 0")
        #expect(result.truncated)
    }

    @Test func editorValueDoesNotRepeatMirroredDescendants() {
        let root = AccessibilityNode(role: "AXWebArea", children: [
            .init(role: "AXTextArea", text: "let total = quantity * price", children: [
                .init(role: "AXStaticText", text: "let total = quantity * price"),
            ]),
        ])

        #expect(AccessibleTextExtractor().extract(root).text == "let total = quantity * price")
    }

    @Test func byteLimitClipsAtUnicodeScalarAndDisclosesLoss() {
        let root = AccessibilityNode(role: "AXWebArea", children: [
            .init(role: "AXStaticText", text: "中文中文"),
        ])

        let result = AccessibleTextExtractor(byteLimit: 7).extract(root)

        #expect(result.text == "中文")
        #expect(result.truncated)
        #expect(result.text.utf8.count <= 7)
    }

    @Test func nodeAndDepthLimitsDiscloseSkippedContent() {
        let deep = AccessibilityNode(role: "AXGroup", children: [
            .init(role: "AXGroup", children: [
                .init(role: "AXStaticText", text: "too deep"),
            ]),
        ])
        let root = AccessibilityNode(role: "AXWebArea", children: [
            .init(role: "AXStaticText", text: "kept"),
            deep,
            .init(role: "AXStaticText", text: "past node limit"),
        ])

        let result = AccessibleTextExtractor(nodeLimit: 4, depthLimit: 2).extract(root)

        #expect(result.text == "kept")
        #expect(result.truncated)
    }

    @Test func whitespaceOnlyTreesProduceEmptyEvidence() {
        let result = AccessibleTextExtractor().extract(
            .init(role: "AXWebArea", children: [
                .init(role: "AXStaticText", text: "  \n "),
            ]))

        #expect(result.text.isEmpty)
        #expect(!result.truncated)
    }
}
