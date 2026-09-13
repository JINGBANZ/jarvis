import Foundation
import JarvisCore

/// Everything `WebSocketConnection` cannot know about a vendor: how to reach it, how to configure a
/// session, how to read a frame, how to name a failure, and what its stream must do at each point in
/// the socket's life.
///
/// The driver calls every method here with its own lock released, so an implementation is free to
/// take its own lock and to call back into the connection. See `WebSocketConnection`'s header for
/// the lock order that makes that safe.
///
/// The connection holds its adapter weakly, so an adapter that is released while a `URLSession`
/// still retains the connection simply makes every callback a no-op. The three constants a
/// connection needs for its own diagnostics (`logPrefix`, `source`, `openDetail`) are passed at init
/// rather than read back through this protocol, for the same reason.
protocol WebSocketConnectionAdapter: AnyObject, Sendable {
    /// The endpoint request. The connection passes it straight to `URLSession` and never logs it:
    /// Gemini's carries the API key in its query string.
    func makeRequest(apiKey: String) -> URLRequest

    /// Send the provider's session configuration. Readiness waits for the acknowledgement it draws.
    func configureSession(on lease: WebSocketConnection.Lease)

    /// One received frame. When it is the provider's configuration acknowledgement, call
    /// `WebSocketConnection.acknowledgeReady`; the driver has no way to recognize it.
    func handle(_ message: URLSessionWebSocketTask.Message, on lease: WebSocketConnection.Lease)

    /// A WebSocket upgrade the edge refused, named by HTTP status.
    func classifyHandshake(status: Int) -> ProviderFailure
    /// A server-initiated close, named by close code and the reason text beside it.
    func classifyClose(code: Int, reason: String?) -> ProviderFailure
    /// Whether a close code on its own is advance warning of a routine rotation rather than a fault.
    /// OpenAI says so with 1001; Gemini warns with a `goAway` frame instead and answers false here.
    func isExpectedRotation(closeCode: Int) -> Bool

    /// A socket is about to open. Reset the per-socket stream state that must not carry over.
    func connectionWillOpen(_ lease: WebSocketConnection.Lease)
    /// The provider acknowledged the configuration. `replacement` is true when an earlier socket in
    /// this session was already ready, so buffered audio is a replay rather than a fresh start.
    func connectionDidBecomeReady(_ lease: WebSocketConnection.Lease, replacement: Bool)
    /// This socket is retired and another will take its place, either after a backoff delay or at
    /// once for an expected rotation. Requeue audio whose delivery was never acknowledged.
    /// `attempt` is the replacement's 1-based ordinal, which a rotation does not advance.
    func connectionWillRetry(_ lease: WebSocketConnection.Lease, attempt: Int)
    /// Transcription is over. Salvage whatever the stream still holds, then report the failure.
    func connectionDidTerminate(_ failure: ProviderFailure)
    /// A user-initiated stop, before the socket is cancelled: the last chance to send a farewell
    /// frame. The lease is already retired, so the raw task is the only way to reach the server.
    func connectionWillClose(_ task: URLSessionWebSocketTask)
}
