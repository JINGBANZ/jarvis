import Foundation

struct AccessibilityWebAreaDescriptor: Sendable, Equatable {
    let index: Int
    let frame: CGRect
    let isDeveloperTools: Bool
}
