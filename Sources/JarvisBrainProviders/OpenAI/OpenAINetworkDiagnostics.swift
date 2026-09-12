import Foundation
import JarvisCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Per-task diagnostics preserve the shared session's connection pooling and cancellation behavior.
/// Only allowlisted metadata enters the audit: never URLs, headers, bodies, or NSError.userInfo text.
/// `@unchecked Sendable` is safe because the sole mutable field is protected by `lock`.
final class OpenAINetworkDiagnostics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var collectedPhases: [String: Int] = [:]

    var phases: [String: Int]? {
        lock.withLock { collectedPhases.isEmpty ? nil : collectedPhases }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        var phases = ["transactions": metrics.transactionMetrics.count, "redirects": metrics.redirectCount]
        for transaction in metrics.transactionMetrics {
            let durations = [
                ("dns_ms", transaction.domainLookupStartDate, transaction.domainLookupEndDate),
                ("connect_ms", transaction.connectStartDate, transaction.connectEndDate),
                ("tls_ms", transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
                ("upload_ms", transaction.requestStartDate, transaction.requestEndDate),
                ("wait_response_ms", transaction.requestEndDate, transaction.responseStartDate),
                ("download_ms", transaction.responseStartDate, transaction.responseEndDate),
            ]
            for (name, start, end) in durations {
                if let start, let end { phases[name, default: 0] += Int(end.timeIntervalSince(start) * 1_000) }
            }
            phases["reused_connections", default: 0] += transaction.isReusedConnection ? 1 : 0
            phases["proxy_connections", default: 0] += transaction.isProxyConnection ? 1 : 0
        }
        lock.withLock { collectedPhases = phases }
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
