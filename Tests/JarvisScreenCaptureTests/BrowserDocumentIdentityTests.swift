import Testing
@testable import JarvisScreenCapture

@Suite struct BrowserDocumentIdentityTests {
    @Test func containsOnlyStableDocumentState() {
        #expect(BrowserDocumentIdentity(value: "document-a") == .init(value: "document-a"))
    }
}
