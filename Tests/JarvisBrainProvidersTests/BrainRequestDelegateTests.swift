import Foundation
import Testing
@testable import JarvisBrainProviders

@Suite struct BrainRequestDelegateTests {
    @Test func errorSummaryKeepsCodesWithoutLeakingErrorPayloads() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSLocalizedDescriptionKey: "secret conversation",
            NSURLErrorFailingURLStringErrorKey: "https://user:secret@example.com/private?token=secret",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 54,
                                         userInfo: [NSLocalizedDescriptionKey: "private payload"]),
        ])
        let summary = BrainRequestDelegate.errorSummary(error)
        #expect(summary == "error_domain=NSURLErrorDomain error_code=-1001 underlying_domain=NSPOSIXErrorDomain underlying_code=54")
        #expect(!summary.contains("secret"))
        #expect(!summary.contains("private"))
    }

    @Test func arbitraryErrorDomainsCannotInjectLogContent() {
        let summary = BrainRequestDelegate.errorSummary(
            NSError(domain: "secret\nforged-log", code: 7))
        #expect(summary == "error_domain=other error_code=7")
    }

    @Test func redirectsAreRefused() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://generativelanguage.googleapis.com")!)
        let response = HTTPURLResponse(
            url: URL(string: "https://generativelanguage.googleapis.com")!, statusCode: 302,
            httpVersion: nil, headerFields: ["Location": "https://elsewhere.example"])!
        let followed = CapturedRequests()
        let answered = CapturedRequests()
        BrainRequestDelegate().urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://elsewhere.example")!)) { next in
            answered.append(URLRequest(url: URL(string: "about:blank")!))
            if let next { followed.append(next) }
        }
        #expect(answered.values.count == 1)
        #expect(followed.values.isEmpty)
    }
}
