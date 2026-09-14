import AppKit
import ApplicationServices
import Foundation
import JarvisCore

public protocol BrowserAccessibilityReading: Sendable {
    func readActiveTab(for window: WindowCandidate) -> ScreenTextEvidence?
}

/// Read-only macOS Accessibility adapter for the exact foreground Chrome window selected for the
/// screenshot. It never prompts, performs actions, changes attributes, or falls back to another
/// Chrome window when bounds cannot identify one uniquely.
public struct BrowserAccessibilityReader: BrowserAccessibilityReading, Sendable {
    private enum Role {
        static let webArea = "AXWebArea"
        static let secureTextField = "AXSecureTextField"
        static let staticText = "AXStaticText"
        static let textField = "AXTextField"
        static let textArea = "AXTextArea"
        static let heading = "AXHeading"
        static let link = "AXLink"
        static let button = "AXButton"
        static let image = "AXImage"
    }

    private static let chromeBundleID = "com.google.Chrome"
    private static let messagingTimeout: Float = 0.25
    private static let positionTolerance = 3.0
    private static let nodeLimit = 4_096
    private static let depthLimit = 64
    private static let searchableNodeLimit = 512

    public init() {}

    public func readActiveTab(for window: WindowCandidate) -> ScreenTextEvidence? {
        guard AXIsProcessTrusted(),
              NSRunningApplication(processIdentifier: pid_t(window.ownerPID))?.bundleIdentifier
                == Self.chromeBundleID
        else { return nil }

        let application = AXUIElementCreateApplication(pid_t(window.ownerPID))
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        guard let axWindow = matchingWindow(in: application, target: window),
              let webArea = firstWebArea(in: axWindow)
        else { return nil }

        var visited = 0
        var sourceTruncated = false
        guard let tree = snapshot(
            webArea,
            depth: 0,
            visited: &visited,
            truncated: &sourceTruncated)
        else { return nil }

        let extraction = AccessibleTextExtractor(
            byteLimit: 32_768,
            nodeLimit: Self.nodeLimit,
            depthLimit: Self.depthLimit
        ).extract(tree)
        guard !extraction.text.isEmpty else { return nil }
        return ScreenTextEvidence(
            text: extraction.text,
            source: .browserAccessibility,
            coverage: .activeTabAccessibilityTree,
            truncated: sourceTruncated || extraction.truncated)
    }

    private func matchingWindow(
        in application: AXUIElement,
        target: WindowCandidate
    ) -> AXUIElement? {
        guard let windows = attribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement]
        else { return nil }
        let matches = windows.filter { window in
            guard let position = pointAttribute(window, kAXPositionAttribute as CFString),
                  let size = sizeAttribute(window, kAXSizeAttribute as CFString)
            else { return false }
            return abs(Double(position.x) - target.x) <= Self.positionTolerance
                && abs(Double(position.y) - target.y) <= Self.positionTolerance
                && abs(Double(size.width) - target.width) <= Self.positionTolerance
                && abs(Double(size.height) - target.height) <= Self.positionTolerance
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func firstWebArea(in root: AXUIElement) -> AXUIElement? {
        var stack = [root]
        var visited = 0
        while let element = stack.popLast(), visited < Self.searchableNodeLimit {
            visited += 1
            if stringAttribute(element, kAXRoleAttribute as CFString) == Role.webArea {
                return element
            }
            let children = (attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
            stack.append(contentsOf: children.reversed())
        }
        return nil
    }

    private func snapshot(
        _ element: AXUIElement,
        depth: Int,
        visited: inout Int,
        truncated: inout Bool
    ) -> AccessibilityNode? {
        guard visited < Self.nodeLimit else {
            truncated = true
            return nil
        }
        visited += 1
        let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let isSecure = role == Role.secureTextField
            || stringAttribute(element, kAXSubroleAttribute as CFString) == Role.secureTextField
        if isSecure {
            return AccessibilityNode(role: role, isSecure: true)
        }

        let rawChildren = (attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
        if depth >= Self.depthLimit {
            if !rawChildren.isEmpty { truncated = true }
            return AccessibilityNode(
                role: role,
                text: semanticText(for: element, role: role),
                isSecure: false)
        }

        var children: [AccessibilityNode] = []
        children.reserveCapacity(min(rawChildren.count, 32))
        for child in rawChildren {
            guard let node = snapshot(
                child,
                depth: depth + 1,
                visited: &visited,
                truncated: &truncated)
            else { break }
            children.append(node)
        }
        return AccessibilityNode(
            role: role,
            text: semanticText(for: element, role: role),
            isSecure: false,
            children: children)
    }

    private func semanticText(for element: AXUIElement, role: String) -> String? {
        let valueRoles: Set<String> = [
            Role.staticText,
            Role.textField,
            Role.textArea,
        ]
        if valueRoles.contains(role),
           let value = stringAttribute(element, kAXValueAttribute as CFString) {
            return value
        }

        let labelledRoles: Set<String> = [
            Role.heading,
            Role.link,
            Role.button,
            Role.image,
        ]
        guard labelledRoles.contains(role) else { return nil }
        return stringAttribute(element, kAXTitleAttribute as CFString)
            ?? stringAttribute(element, kAXDescriptionAttribute as CFString)
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    private func pointAttribute(_ element: AXUIElement, _ name: CFString) -> CGPoint? {
        guard let raw = attribute(element, name),
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ name: CFString) -> CGSize? {
        guard let raw = attribute(element, name),
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }
}
