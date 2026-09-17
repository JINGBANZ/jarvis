import Foundation

/// Value-only: AX objects stay at the macOS edge and never cross into parsing or async state.
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
