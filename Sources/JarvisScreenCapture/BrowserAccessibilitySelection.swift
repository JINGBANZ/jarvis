import Foundation
import JarvisCore

struct AccessibilityWindowDescriptor: Sendable, Equatable {
    let frame: CGRect
    let isFocused: Bool
    let isMain: Bool
}

struct AccessibilityWebAreaDescriptor: Sendable, Equatable {
    let index: Int
    let frame: CGRect
    let isDeveloperTools: Bool
}

enum BrowserAccessibilitySelection {
    private static let positionTolerance = 3.0

    static func windowIndex(
        in windows: [AccessibilityWindowDescriptor],
        target: WindowCandidate
    ) -> Int? {
        let matches = windows.indices.filter { index in
            let frame = windows[index].frame
            return abs(frame.origin.x - target.x) <= positionTolerance
                && abs(frame.origin.y - target.y) <= positionTolerance
                && abs(frame.width - target.width) <= positionTolerance
                && abs(frame.height - target.height) <= positionTolerance
        }
        if matches.count == 1 { return matches[0] }
        return matches.first { windows[$0].isFocused }
            ?? matches.first { windows[$0].isMain }
    }

    static func webAreaIndex(in areas: [AccessibilityWebAreaDescriptor]) -> Int? {
        let pageAreas = areas.filter { !$0.isDeveloperTools }
        return pageAreas.max { left, right in
            left.frame.width * left.frame.height < right.frame.width * right.frame.height
        }?.index
    }
}

enum AccessibilityTraversal {
    static func editorElements<Element>(
        in roots: [Element],
        role: (Element) -> String,
        children: (Element) -> [Element],
        limit: Int
    ) -> [Element] {
        var queue = roots
        var cursor = 0
        var visited = 0
        var textAreas: [Element] = []
        var textFields: [Element] = []
        while cursor < queue.count, visited < limit {
            let element = queue[cursor]
            cursor += 1
            visited += 1
            switch role(element) {
            case "AXTextArea":
                textAreas.append(element)
            case "AXTextField":
                textFields.append(element)
            case "AXSecureTextField":
                continue
            default:
                let remaining = max(0, limit - queue.count)
                queue.append(contentsOf: children(element).prefix(remaining))
            }
        }
        return textAreas + textFields
    }
}

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
