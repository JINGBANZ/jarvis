import Foundation

/// Value-only snapshot of the small Accessibility subtree the extractor needs. AX objects stay at
/// the macOS edge and never cross into parsing tests or asynchronous state.
struct AccessibilityNode: Sendable, Equatable {
    let role: String
    let text: String?
    let children: [AccessibilityNode]

    init(role: String, text: String? = nil, children: [AccessibilityNode] = []) {
        self.role = role
        self.text = text
        self.children = children
    }
}
