import Foundation
import JarvisCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Per-task diagnostics preserve the shared session's connection pooling and cancellation behavior.
/// Only allowlisted metadata is logged: never URLs, headers, bodies, or NSError.userInfo text.
final class OpenAINetworkDiagnostics: NSObject, URLSessionTaskDelegate, Sendable {
    private let id = UUID().uuidString
    private let started = ContinuousClock.now
    private let timeout: TimeInterval

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    func completed(status: Int? = nil, error: Error? = nil) {
        let elapsed = started.duration(to: .now).components
        let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        let result = error.map(Self.errorSummary) ?? "http_status=\(status.map(String.init) ?? "unavailable")"
        jlog("Jarvis OpenAI transport id=\(id) elapsed_ms=\(milliseconds) timeout_s=\(timeout) \(result)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        jlog("Jarvis OpenAI transport id=\(id) transactions=\(metrics.transactionMetrics.count) redirects=\(metrics.redirectCount)")
        for (index, transaction) in metrics.transactionMetrics.enumerated() {
            let phases = [
                "dns_ms=\(Self.milliseconds(transaction.domainLookupStartDate, transaction.domainLookupEndDate))",
                "connect_ms=\(Self.milliseconds(transaction.connectStartDate, transaction.connectEndDate))",
                "tls_ms=\(Self.milliseconds(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate))",
                "upload_ms=\(Self.milliseconds(transaction.requestStartDate, transaction.requestEndDate))",
                "wait_response_ms=\(Self.milliseconds(transaction.requestEndDate, transaction.responseStartDate))",
                "download_ms=\(Self.milliseconds(transaction.responseStartDate, transaction.responseEndDate))",
            ].joined(separator: " ")
            jlog("Jarvis OpenAI transport id=\(id) transaction=\(index) reused=\(transaction.isReusedConnection) proxy=\(transaction.isProxyConnection) \(phases)")
        }
    }

    /// Missing endpoints are explicitly unavailable, not zero: a failed connection may never finish
    /// DNS/TLS, and a reused connection can legitimately have no DNS/TLS measurements at all.
    private static func milliseconds(_ start: Date?, _ end: Date?) -> String {
        guard let start, let end else { return "unavailable" }
        return String(Int(end.timeIntervalSince(start) * 1_000))
    }

    static func errorSummary(_ error: Error) -> String {
        let error = error as NSError
        var result = "error_domain=\(safeDomain(error.domain)) error_code=\(error.code)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            result += " underlying_domain=\(safeDomain(underlying.domain)) underlying_code=\(underlying.code)"
        }
        return result
    }

    private static func safeDomain(_ domain: String) -> String {
        switch domain {
        case NSURLErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain,
             "kCFErrorDomainCFNetwork", "kCFErrorDomainSSL", "NSOSStatusErrorDomain": domain
        default: "other"
        }
    }
}
