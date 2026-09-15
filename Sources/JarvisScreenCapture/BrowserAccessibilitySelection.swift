import Foundation
import JarvisCore

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
