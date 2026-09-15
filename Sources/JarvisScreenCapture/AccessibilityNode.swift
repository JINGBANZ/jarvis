import Foundation

/// Value-only snapshot of the small Accessibility subtree the extractor needs. AX objects stay at
/// the macOS edge and never cross into parsing tests or asynchronous state.
struct AccessibilityNode: Sendable, Equatable {
    let role: String
    let text: String?
    let isSecure: Bool
    let children: [AccessibilityNode]

    init(
        role: String,
        text: String? = nil,
        isSecure: Bool = false,
        children: [AccessibilityNode] = []
    ) {
        self.role = role
        self.text = text
        self.isSecure = isSecure
        self.children = children
    }
}
