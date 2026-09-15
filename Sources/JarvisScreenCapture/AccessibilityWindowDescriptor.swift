import Foundation

struct AccessibilityWindowDescriptor: Sendable, Equatable {
    let frame: CGRect
    let isFocused: Bool
    let isMain: Bool
}
