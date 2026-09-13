import Foundation
import Testing
@testable import JarvisBrainProviders

@Suite struct OpenAINetworkDiagnosticsTests {
    @Test func errorSummaryKeepsCodesWithoutLeakingErrorPayloads() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSLocalizedDescriptionKey: "secret conversation",
            NSURLErrorFailingURLStringErrorKey: "https://user:secret@example.com/private?token=secret",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 54,
                                         userInfo: [NSLocalizedDescriptionKey: "private payload"]),
        ])
        let summary = OpenAINetworkDiagnostics.errorSummary(error)
        #expect(summary == "error_domain=NSURLErrorDomain error_code=-1001 underlying_domain=NSPOSIXErrorDomain underlying_code=54")
        #expect(!summary.contains("secret"))
        #expect(!summary.contains("private"))
    }

    @Test func arbitraryErrorDomainsCannotInjectLogContent() {
        let summary = OpenAINetworkDiagnostics.errorSummary(
            NSError(domain: "secret\nforged-log", code: 7))
        #expect(summary == "error_domain=other error_code=7")
    }
}
