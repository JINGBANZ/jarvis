/// Emitted from any callback queue.
public enum TranscriptionConnectionState: Sendable, Equatable {
    case connecting
    case ready
    case reconnecting(attempt: Int)
    case failed
    case stopped
}
