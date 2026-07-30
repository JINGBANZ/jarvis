/// User-visible lifecycle of one transcription endpoint. The mic-side state drives the menu-bar
/// health indicator; the system-audio side can degrade independently without stopping mic coaching.
/// Emitted by an OS-bound provider adapter from any callback queue.
public enum TranscriptionConnectionState: Sendable, Equatable {
    case connecting
    case ready
    case reconnecting(attempt: Int)
    case failed
    case stopped
}
