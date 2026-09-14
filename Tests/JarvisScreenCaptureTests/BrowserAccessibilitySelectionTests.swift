import Foundation
import JarvisCore
import Testing
@testable import JarvisScreenCapture

@Suite struct BrowserAccessibilitySelectionTests {
    @Test func focusedWindowBreaksIdenticalBoundsTie() {
        let target = WindowCandidate(
            windowID: 1, ownerPID: 2, layer: 0,
            x: 10, y: 20, width: 900, height: 700)
        let windows = [
            AccessibilityWindowDescriptor(
                frame: CGRect(x: 10, y: 20, width: 900, height: 700),
                isFocused: false, isMain: false),
            AccessibilityWindowDescriptor(
                frame: CGRect(x: 10, y: 20, width: 900, height: 700),
                isFocused: true, isMain: true),
        ]

        #expect(BrowserAccessibilitySelection.windowIndex(in: windows, target: target) == 1)
    }

    @Test func pageWebAreaWinsOverLargerDockedDeveloperTools() {
        let areas = [
            AccessibilityWebAreaDescriptor(
                index: 4, frame: CGRect(x: 0, y: 0, width: 980, height: 700),
                isDeveloperTools: true),
            AccessibilityWebAreaDescriptor(
                index: 7, frame: CGRect(x: 980, y: 0, width: 420, height: 700),
                isDeveloperTools: false),
        ]

        #expect(BrowserAccessibilitySelection.webAreaIndex(in: areas) == 7)
    }

    @Test func traversalBudgetBoundsElapsedTimeAndTextBytes() {
        let budget = AccessibilityReadBudget(deadline: 10, byteLimit: 7)

        #expect(budget.remaining(at: 9.75) == 0.25)
        #expect(budget.remaining(at: 11) == 0)
        #expect(budget.take("中文中文") == "中文")
        #expect(budget.byteLimitReached)
    }

    @Test func nestedEditorsAreDiscoveredBeforeSnapshotTextIsConsumed() {
        let navigation = AccessibilityNode(role: "AXNavigation", children: [
            .init(role: "AXGroup", children: [
                .init(role: "AXStaticText", text: String(repeating: "noise", count: 10_000)),
            ]),
        ])
        let editorWrapper = AccessibilityNode(role: "AXGroup", children: [
            .init(role: "AXGroup", children: [
                .init(role: "AXTextArea", text: "guard quantity >= 0"),
            ]),
        ])

        let editors = AccessibilityTraversal.editorElements(
            in: [navigation, editorWrapper],
            role: { $0.role },
            children: { $0.children },
            limit: 32)

        #expect(editors.map(\.text) == ["guard quantity >= 0"])
    }
}
