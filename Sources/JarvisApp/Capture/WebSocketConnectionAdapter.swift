import Foundation
import JarvisCore

/// The connection calls every method with its own lock released, so an implementation may take its
/// own lock and call back into the connection.
protocol WebSocketConnectionAdapter: AnyObject, Sendable {
    /// Never log the request: Gemini's carries the API key in its query string.
    func makeRequest(apiKey: String) -> URLRequest

    func configureSession(on lease: WebSocketConnection.Lease)

    /// Call `WebSocketConnection.acknowledgeReady` on the configuration acknowledgement frame.
    func handle(_ message: URLSessionWebSocketTask.Message, on lease: WebSocketConnection.Lease)

    func classifyHandshake(status: Int) -> ProviderFailure
    func classifyClose(code: Int, reason: String?) -> ProviderFailure
    func isExpectedRotation(closeCode: Int) -> Bool

    /// Reset the per-socket stream state that must not carry over.
    func connectionWillOpen(_ lease: WebSocketConnection.Lease)
    /// `replacement`: an earlier socket in this session was ready, so buffered audio is a replay.
    func connectionDidBecomeReady(_ lease: WebSocketConnection.Lease, replacement: Bool)
    /// Another socket follows, now or after backoff. Requeue audio the server never acknowledged.
    /// `attempt` is 1-based, and a rotation does not advance it.
    func connectionWillRetry(_ lease: WebSocketConnection.Lease, attempt: Int)
    /// Salvage whatever the stream still holds, then report the failure.
    func connectionDidTerminate(_ failure: ProviderFailure)
    /// A user stop, before the cancel: the last chance for a farewell frame. The lease is already
    /// retired, so the raw task is the only way to reach the server.
    func connectionWillClose(_ task: URLSessionWebSocketTask)
}
