#if JARVIS_LIVE_E2E
import Foundation

final class LiveE2ECacheRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    // The request carries authorization; forwarding it also escapes the fixed-target budget.
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
#endif
