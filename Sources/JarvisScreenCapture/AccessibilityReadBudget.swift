import Foundation

/// Bounds one Accessibility-tree pass by elapsed time and extracted UTF-8 bytes.
final class AccessibilityReadBudget {
    let deadline: TimeInterval
    private let byteLimit: Int
    private(set) var byteCount = 0
    private(set) var clippedText = false

    init(deadline: TimeInterval, byteLimit: Int) {
        self.deadline = deadline
        self.byteLimit = max(0, byteLimit)
    }

    func remaining(at now: TimeInterval) -> TimeInterval {
        max(0, deadline - now)
    }

    var remaining: TimeInterval {
        remaining(at: ProcessInfo.processInfo.systemUptime)
    }

    var isExpired: Bool { remaining <= 0 }
    var byteLimitReached: Bool { clippedText || byteCount >= byteLimit }

    func take(_ text: String) -> String {
        let available = max(0, byteLimit - byteCount)
        var bytes = 0
        var end = text.unicodeScalars.startIndex
        for scalar in text.unicodeScalars {
            guard bytes + scalar.utf8.count <= available else { break }
            bytes += scalar.utf8.count
            end = text.unicodeScalars.index(after: end)
        }
        let result = String(text[..<end])
        byteCount += result.utf8.count
        if result.utf8.count < text.utf8.count { clippedText = true }
        return result
    }
}
