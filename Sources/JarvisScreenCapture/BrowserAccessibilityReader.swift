import AppKit
import ApplicationServices
import Foundation
import JarvisCore

public struct BrowserDocumentIdentity: Sendable, Equatable {
    let value: String
    let deadline: TimeInterval

    init(value: String, deadline: TimeInterval) {
        self.value = value
        self.deadline = deadline
    }
}

public protocol BrowserAccessibilityReading: Sendable {
    func documentIdentity(for window: WindowCandidate) -> BrowserDocumentIdentity?
    func readActiveTab(
        for window: WindowCandidate,
        matching documentIdentity: BrowserDocumentIdentity
    ) -> ScreenTextEvidence?
}

/// Read-only macOS Accessibility adapter for the exact foreground Chrome window selected for the
/// screenshot. It never prompts, performs actions, changes attributes, or reads another Chrome
/// window when the selected window cannot be matched.
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
    private static let readDeadline: TimeInterval = 0.75
    private static let identityVerificationReserve: TimeInterval = 0.1
    private static let primingDeadline: TimeInterval = 1.5
    private static let byteLimit = 32_768
    private static let nodeLimit = 4_096
    private static let depthLimit = 64
    private static let searchableNodeLimit = 512
    private static let primedProcesses = PrimedProcesses()

    private final class PrimedProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: Set<pid_t> = []

        func claim(_ pid: pid_t) -> Bool {
            lock.withLock { pids.insert(pid).inserted }
        }
    }

    public init() {}

    public func documentIdentity(for window: WindowCandidate) -> BrowserDocumentIdentity? {
        guard let application = preparedApplication(for: window) else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + Self.readDeadline
        let budget = AccessibilityReadBudget(
            deadline: deadline,
            byteLimit: Self.byteLimit)
        _ = attribute(application, kAXRoleAttribute as CFString, budget: budget)
        guard let axWindow = matchingWindow(in: application, target: window, budget: budget),
              let page = pageWebArea(in: axWindow, budget: budget)
        else { return nil }
        return BrowserDocumentIdentity(
            value: identity(for: page.element, url: page.url, window: window),
            deadline: deadline)
    }

    public func readActiveTab(
        for window: WindowCandidate,
        matching documentIdentity: BrowserDocumentIdentity
    ) -> ScreenTextEvidence? {
        guard let application = preparedApplication(for: window) else { return nil }
        let deadline = documentIdentity.deadline
        let budget = AccessibilityReadBudget(deadline: deadline, byteLimit: Self.byteLimit)
        _ = attribute(application, kAXRoleAttribute as CFString, budget: budget)
        guard let axWindow = matchingWindow(in: application, target: window, budget: budget) else {
            jlog("🔤 browser text unavailable — foreground window could not be matched")
            return nil
        }
        guard let page = pageWebArea(in: axWindow, budget: budget),
              identity(for: page.element, url: page.url, window: window) == documentIdentity.value
        else {
            jlog("🔤 browser text unavailable — active tab changed during capture")
            return nil
        }
        let webArea = page.element
        let traversalBudget = AccessibilityReadBudget(
            deadline: deadline - Self.identityVerificationReserve,
            byteLimit: Self.byteLimit)

        var visited = 0
        var sourceTruncated = false
        let editors = editorElements(in: webArea, budget: traversalBudget)
        var editorNodes: [AccessibilityNode] = []
        for editor in editors {
            guard let node = snapshot(
                editor,
                depth: 1,
                visited: &visited,
                budget: traversalBudget,
                excluding: [],
                truncated: &sourceTruncated)
            else { break }
            editorNodes.append(node)
        }
        let generalTree = snapshot(
            webArea,
            depth: 0,
            visited: &visited,
            budget: traversalBudget,
            excluding: editors,
            truncated: &sourceTruncated)
        guard generalTree != nil || !editorNodes.isEmpty else { return nil }
        guard let verifiedPage = pageWebArea(in: axWindow, budget: budget),
              identity(
                  for: verifiedPage.element,
                  url: verifiedPage.url,
                  window: window) == documentIdentity.value
        else {
            jlog("🔤 browser text unavailable — active tab changed while reading")
            return nil
        }
        let tree = AccessibilityNode(
            role: generalTree?.role ?? Role.webArea,
            text: generalTree?.text,
            isSecure: generalTree?.isSecure ?? false,
            children: editorNodes + (generalTree?.children ?? []))

        let extraction = AccessibleTextExtractor(
            byteLimit: Self.byteLimit,
            nodeLimit: Self.nodeLimit,
            depthLimit: Self.depthLimit
        ).extract(tree)
        guard !extraction.text.isEmpty else {
            jlog("🔤 browser text unavailable — active tab exposed no semantic text")
            return nil
        }
        return ScreenTextEvidence(
            text: extraction.text,
            source: .browserAccessibility,
            coverage: .activeTabAccessibilityTree,
            truncated: sourceTruncated || extraction.truncated)
    }

    private func preparedApplication(for window: WindowCandidate) -> AXUIElement? {
        guard AXIsProcessTrusted() else {
            jlog("🔤 browser text unavailable — Accessibility permission is not granted")
            return nil
        }
        guard NSRunningApplication(processIdentifier: pid_t(window.ownerPID))?.bundleIdentifier
                == Self.chromeBundleID
        else {
            jlog("🔤 browser text unavailable — foreground app is not supported")
            return nil
        }

        let pid = pid_t(window.ownerPID)
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        // Chromium creates its web accessibility tree lazily after the first application-level AX
        // read. This read-only probe is the supported trigger; never write the manual-accessibility
        // or enhanced-interface attributes.
        if Self.primedProcesses.claim(pid) {
            let primingBudget = AccessibilityReadBudget(
                deadline: ProcessInfo.processInfo.systemUptime + Self.primingDeadline,
                byteLimit: Self.byteLimit)
            _ = attribute(application, kAXRoleAttribute as CFString, budget: primingBudget)
            primeWebArea(in: application, target: window, budget: primingBudget)
        }
        return application
    }

    private func matchingWindow(
        in application: AXUIElement,
        target: WindowCandidate,
        budget: AccessibilityReadBudget
    ) -> AXUIElement? {
        guard let windows = attribute(
            application, kAXWindowsAttribute as CFString, budget: budget) as? [AXUIElement]
        else { return nil }
        let descriptors = windows.map { window -> AccessibilityWindowDescriptor in
            let position = pointAttribute(window, kAXPositionAttribute as CFString, budget: budget)
                ?? .zero
            let size = sizeAttribute(window, kAXSizeAttribute as CFString, budget: budget) ?? .zero
            return AccessibilityWindowDescriptor(
                frame: CGRect(origin: position, size: size),
                isFocused: boolAttribute(window, kAXFocusedAttribute as CFString, budget: budget),
                isMain: boolAttribute(window, kAXMainAttribute as CFString, budget: budget))
        }
        guard let index = BrowserAccessibilitySelection.windowIndex(
            in: descriptors, target: target) else { return nil }
        return windows[index]
    }

    private struct PageWebArea {
        let element: AXUIElement
        let url: String
    }

    private func pageWebArea(
        in root: AXUIElement, budget: AccessibilityReadBudget
    ) -> PageWebArea? {
        var stack = [root]
        var visited = 0
        var areas: [(page: PageWebArea, descriptor: AccessibilityWebAreaDescriptor)] = []
        while let element = stack.popLast(), visited < Self.searchableNodeLimit, !budget.isExpired {
            visited += 1
            if stringAttribute(element, kAXRoleAttribute as CFString, budget: budget) == Role.webArea {
                let position = pointAttribute(element, kAXPositionAttribute as CFString, budget: budget)
                    ?? .zero
                let size = sizeAttribute(element, kAXSizeAttribute as CFString, budget: budget) ?? .zero
                let rawURL = attribute(element, kAXURLAttribute as CFString, budget: budget)
                let url = (rawURL as? URL)?.absoluteString ?? rawURL as? String ?? ""
                areas.append((.init(element: element, url: url), .init(
                    index: areas.count,
                    frame: CGRect(origin: position, size: size),
                    isDeveloperTools: url.hasPrefix("devtools://"))))
                continue
            }
            let children = (attribute(
                element, kAXChildrenAttribute as CFString, budget: budget) as? [AXUIElement]) ?? []
            stack.append(contentsOf: children.reversed())
        }
        guard let index = BrowserAccessibilitySelection.webAreaIndex(
            in: areas.map(\.descriptor)) else { return nil }
        return areas[index].page
    }

    private func primeWebArea(
        in application: AXUIElement,
        target: WindowCandidate,
        budget: AccessibilityReadBudget
    ) {
        repeat {
            if let window = matchingWindow(in: application, target: target, budget: budget),
               let webArea = pageWebArea(in: window, budget: budget),
               let children = attribute(
                    webArea.element, kAXChildrenAttribute as CFString, budget: budget) as? [AXUIElement],
               !children.isEmpty {
                return
            }
            let pause = min(0.05, budget.remaining)
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        } while !budget.isExpired
    }

    private func identity(
        for webArea: AXUIElement,
        url: String,
        window: WindowCandidate
    ) -> String {
        "\(window.ownerPID):\(window.windowID):\(CFHash(webArea)):\(url)"
    }

    private func editorElements(
        in webArea: AXUIElement,
        budget: AccessibilityReadBudget
    ) -> [AXUIElement] {
        AccessibilityTraversal.editorElements(
            in: [webArea],
            role: { stringAttribute($0, kAXRoleAttribute as CFString, budget: budget) ?? "" },
            children: {
                (attribute($0, kAXChildrenAttribute as CFString, budget: budget)
                    as? [AXUIElement]) ?? []
            },
            limit: Self.searchableNodeLimit)
    }

    private func snapshot(
        _ element: AXUIElement,
        depth: Int,
        visited: inout Int,
        budget: AccessibilityReadBudget,
        excluding excludedElements: [AXUIElement],
        truncated: inout Bool
    ) -> AccessibilityNode? {
        guard visited < Self.nodeLimit, !budget.isExpired, !budget.byteLimitReached else {
            truncated = true
            return nil
        }
        visited += 1
        let role = stringAttribute(element, kAXRoleAttribute as CFString, budget: budget) ?? ""
        let isSecure = role == Role.secureTextField
            || stringAttribute(
                element, kAXSubroleAttribute as CFString, budget: budget) == Role.secureTextField
        if isSecure {
            return AccessibilityNode(role: role, isSecure: true)
        }

        let rawText = semanticText(for: element, role: role, budget: budget)
        let text = rawText.map(budget.take)
        if let rawText, let text {
            if text.utf8.count < rawText.utf8.count { truncated = true }
        }
        if [Role.textArea, Role.textField].contains(role), text?.isEmpty == false {
            return AccessibilityNode(role: role, text: text, isSecure: false)
        }
        if budget.byteLimitReached {
            truncated = true
            return AccessibilityNode(role: role, text: text, isSecure: false)
        }

        let rawChildren = (attribute(
            element, kAXChildrenAttribute as CFString, budget: budget) as? [AXUIElement]) ?? []
        if depth >= Self.depthLimit {
            if !rawChildren.isEmpty { truncated = true }
            return AccessibilityNode(
                role: role,
                text: text,
                isSecure: false)
        }

        let editorRoles: Set<String> = [Role.textArea, Role.textField]
        let orderedChildren = rawChildren.enumerated().map { index, child in
            (index, child, stringAttribute(child, kAXRoleAttribute as CFString, budget: budget) ?? "")
        }.sorted { left, right in
            let leftEditor = editorRoles.contains(left.2)
            let rightEditor = editorRoles.contains(right.2)
            return leftEditor == rightEditor ? left.0 < right.0 : leftEditor
        }
        var children: [AccessibilityNode] = []
        children.reserveCapacity(min(rawChildren.count, 32))
        for (_, child, _) in orderedChildren {
            if excludedElements.contains(where: { CFEqual($0, child) }) { continue }
            guard let node = snapshot(
                child,
                depth: depth + 1,
                visited: &visited,
                budget: budget,
                excluding: excludedElements,
                truncated: &truncated)
            else { break }
            children.append(node)
        }
        return AccessibilityNode(
            role: role,
            text: text,
            isSecure: false,
            children: children)
    }

    private func semanticText(
        for element: AXUIElement, role: String, budget: AccessibilityReadBudget
    ) -> String? {
        let valueRoles: Set<String> = [
            Role.staticText,
            Role.textField,
            Role.textArea,
        ]
        if valueRoles.contains(role),
           let value = stringAttribute(element, kAXValueAttribute as CFString, budget: budget) {
            return value
        }

        let labelledRoles: Set<String> = [
            Role.heading,
            Role.link,
            Role.button,
            Role.image,
        ]
        guard labelledRoles.contains(role) else { return nil }
        return stringAttribute(element, kAXTitleAttribute as CFString, budget: budget)
            ?? stringAttribute(element, kAXDescriptionAttribute as CFString, budget: budget)
    }

    private func attribute(
        _ element: AXUIElement, _ name: CFString, budget: AccessibilityReadBudget? = nil
    ) -> CFTypeRef? {
        if let budget {
            guard !budget.isExpired else { return nil }
            AXUIElementSetMessagingTimeout(
                element, Float(min(TimeInterval(Self.messagingTimeout), budget.remaining)))
        } else {
            AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func stringAttribute(
        _ element: AXUIElement, _ name: CFString, budget: AccessibilityReadBudget? = nil
    ) -> String? {
        attribute(element, name, budget: budget) as? String
    }

    private func boolAttribute(
        _ element: AXUIElement, _ name: CFString, budget: AccessibilityReadBudget
    ) -> Bool {
        attribute(element, name, budget: budget) as? Bool ?? false
    }

    private func pointAttribute(
        _ element: AXUIElement, _ name: CFString, budget: AccessibilityReadBudget
    ) -> CGPoint? {
        guard let raw = attribute(element, name, budget: budget),
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(
        _ element: AXUIElement, _ name: CFString, budget: AccessibilityReadBudget
    ) -> CGSize? {
        guard let raw = attribute(element, name, budget: budget),
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }
}
