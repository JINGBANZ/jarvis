import JarvisCore

public protocol BrowserAccessibilityReading: Sendable {
    func documentIdentity(for window: WindowCandidate) -> BrowserDocumentIdentity?
    func readActiveTab(
        for window: WindowCandidate,
        matching documentIdentity: BrowserDocumentIdentity
    ) -> ScreenTextEvidence?
}
